package org.foldersafe.interop;

import com.google.common.io.BaseEncoding;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.cryptomator.cryptofs.VaultConfig;
import org.cryptomator.cryptolib.api.Cryptor;
import org.cryptomator.cryptolib.api.CryptorProvider;
import org.cryptomator.cryptolib.api.FileContentCryptor;
import org.cryptomator.cryptolib.api.FileHeader;
import org.cryptomator.cryptolib.api.FileHeaderCryptor;
import org.cryptomator.cryptolib.api.FileNameCryptor;
import org.cryptomator.cryptolib.api.Masterkey;
import org.cryptomator.cryptolib.common.MasterkeyFileAccess;
import org.cryptomator.cryptolib.common.Scrypt;
import org.cryptomator.siv.SivMode;

import javax.crypto.spec.SecretKeySpec;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.lang.reflect.Constructor;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;

/**
 * Cross-checks the L1 sections of docs/spec/test-vectors/v1.json against Cryptomator's own cryptolib / cryptofs.
 * Prints one ✓/✗ line per check on stdout; throws (→ exit 1) if any check fails.
 */
final class VectorCheck {

	/** Pepper used by the Cryptomator desktop app: org.cryptomator.common.Constants.PEPPER = new byte[0]. */
	private static final byte[] DESKTOP_PEPPER = new byte[0];
	private static final HexFormat HEX = HexFormat.of();

	private int passed;
	private final List<String> failed = new ArrayList<>();

	private VectorCheck() {
	}

	static void run(Path file) throws Exception {
		VectorCheck vc = new VectorCheck();
		vc.checkAll(JsonParser.parseString(Files.readString(file)).getAsJsonObject());
		System.out.println((vc.failed.isEmpty() ? "✓" : "✗") + " test vectors: " + vc.passed + " passed, " + vc.failed.size() + " failed");
		if (!vc.failed.isEmpty()) {
			throw new IOException("test vector mismatch: " + String.join("; ", vc.failed));
		}
	}

	private void checkAll(JsonObject v) throws Exception {
		// ---- keys
		JsonObject keys = v.getAsJsonObject("keys");
		byte[] encKey = hex(keys, "encKey");
		byte[] macKey = hex(keys, "macKey");
		Masterkey masterkey = Masterkey.from(new org.cryptomator.cryptolib.common.DestroyableSecretKey(encKey, Masterkey.ENC_ALG),
				new org.cryptomator.cryptolib.common.DestroyableSecretKey(macKey, Masterkey.MAC_ALG));
		byte[] rawKey = masterkey.getEncoded();
		check("keys.rawKey == Masterkey(encKey, macKey).getEncoded() (encKey||macKey)", Arrays.equals(rawKey, hex(keys, "rawKey")));
		byte[] sivKey = concat(macKey, encKey);
		if (keys.has("sivKey_K1cmac_K2ctr")) {
			check("keys.sivKey_K1cmac_K2ctr == macKey||encKey", Arrays.equals(sivKey, hex(keys, "sivKey_K1cmac_K2ctr")));
		}

		// ---- scrypt (cryptolib's own implementation)
		if (v.has("scrypt")) {
			JsonObject s = v.getAsJsonObject("scrypt");
			byte[] out = Scrypt.scrypt(s.get("password").getAsString().getBytes(StandardCharsets.UTF_8), hex(s, "salt"),
					s.get("N").getAsInt(), s.get("r").getAsInt(), s.get("dkLen").getAsInt());
			check("scrypt (cryptolib Scrypt, p=1) N=" + s.get("N").getAsInt(), s.get("p").getAsInt() == 1 && Arrays.equals(out, hex(s, "output")));
		}

		// ---- AES-SIV: the exact call cryptolib's v2 FileNameCryptorImpl makes: SivMode.encrypt(ctrKey=encKey, macKey=macKey, ...)
		int i = 0;
		for (JsonElement e : v.getAsJsonArray("aesSiv")) {
			JsonObject o = e.getAsJsonObject();
			byte[] key = hex(o, "key");
			byte[][] ad = hexList(o.getAsJsonArray("associatedData"));
			byte[] expected = hex(o, "ciphertext");
			byte[] pt = hex(o, "plaintext");
			String label = "aesSiv[" + i++ + "] (pt " + pt.length + " B, " + ad.length + " AD)";
			check(label + " key == macKey||encKey", Arrays.equals(key, sivKey));
			byte[] k1 = Arrays.copyOfRange(key, 0, 32);
			byte[] k2 = Arrays.copyOfRange(key, 32, 64);
			try (var ctr = new org.cryptomator.cryptolib.common.DestroyableSecretKey(k2, "AES");
				 var mac = new org.cryptomator.cryptolib.common.DestroyableSecretKey(k1, "AES")) {
				check(label + " cryptolib-style SivMode.encrypt(ctrKey=K2, macKey=K1)", Arrays.equals(new SivMode().encrypt(ctr, mac, pt, ad), expected));
			}
			check(label + " RFC 5297 single-key SivMode.encrypt(K1||K2)", Arrays.equals(new SivMode().encrypt(new SecretKeySpec(key, "AES"), pt, ad), expected));
		}

		// ---- masterkey file
		JsonObject mkf = v.getAsJsonObject("masterkeyFile");
		String password = mkf.get("password").getAsString();
		String nfc = Normalizer.normalize(password, Normalizer.Form.NFC);
		if (mkf.has("passwordUtf8NFC")) {
			check("masterkeyFile.passwordUtf8NFC == UTF-8(NFC(password))", Arrays.equals(nfc.getBytes(StandardCharsets.UTF_8), hex(mkf, "passwordUtf8NFC")));
		}
		if (mkf.has("kek") && mkf.has("scryptSalt")) {
			byte[] kek = Scrypt.scrypt(nfc, hex(mkf, "scryptSalt"), mkf.get("N").getAsInt(), mkf.get("r").getAsInt(), 32);
			check("masterkeyFile.kek == scrypt(NFC password, salt)", Arrays.equals(kek, hex(mkf, "kek")));
		}
		byte[] fileBytes = mkf.get("file").getAsString().getBytes(StandardCharsets.UTF_8);
		try (Masterkey loaded = new MasterkeyFileAccess(DESKTOP_PEPPER, new SecureRandom()).load(new ByteArrayInputStream(fileBytes), nfc)) {
			check("masterkeyFile: MasterkeyFileAccess(pepper = empty, as Cryptomator desktop).load → encKey", Arrays.equals(loaded.getEncKey().getEncoded(), encKey));
			check("masterkeyFile: MasterkeyFileAccess.load → macKey", Arrays.equals(loaded.getMacKey().getEncoded(), macKey));
		} catch (Exception ex) {
			check("masterkeyFile: MasterkeyFileAccess.load failed: " + ex, false);
		}

		// ---- vault config
		JsonObject vcj = v.getAsJsonObject("vaultConfig");
		var unverified = VaultConfig.decode(vcj.get("token").getAsString());
		check("vaultConfig kid == masterkeyfile:masterkey.cryptomator", unverified.getKeyId().toString().equals("masterkeyfile:masterkey.cryptomator"));
		int threshold = 220;
		try {
			VaultConfig config = unverified.verify(rawKey, 8); // throws on bad signature or format != 8
			check("vaultConfig: cryptofs VaultConfig.verify(rawKey, format 8) (" + unverified.getHeader("alg", String.class) + ")", config.getVaultVersion() == 8);
			check("vaultConfig jti == vaultId", config.getId().equals(vcj.get("vaultId").getAsString()));
			check("vaultConfig cipherCombo == SIV_GCM", config.getCipherCombo() == CryptorProvider.Scheme.SIV_GCM);
			check("vaultConfig shorteningThreshold == 220", config.getShorteningThreshold() == 220);
			threshold = config.getShorteningThreshold();
		} catch (Exception ex) {
			check("vaultConfig: cryptofs VaultConfig.verify failed: " + ex, false);
		}

		Cryptor cryptor = CryptorProvider.forScheme(CryptorProvider.Scheme.SIV_GCM).provide(masterkey.copy(), new SecureRandom());
		FileNameCryptor names = cryptor.fileNameCryptor();

		// ---- directory paths
		for (JsonElement e : v.getAsJsonArray("dirPaths")) {
			JsonObject o = e.getAsJsonObject();
			String dirId = o.get("dirId").getAsString();
			String h = names.hashDirectoryId(dirId);
			String path = "d/" + h.substring(0, 2) + "/" + h.substring(2);
			check("dirPaths '" + dirId + "' → " + o.get("path").getAsString(), path.equals(o.get("path").getAsString()));
		}

		// ---- names (+ cryptofs shortening rule: name length incl. ".c9r" > shorteningThreshold → base64url(SHA-1(encName)) + ".c9s")
		for (JsonElement e : v.getAsJsonArray("names")) {
			JsonObject o = e.getAsJsonObject();
			String name = Normalizer.normalize(o.get("name").getAsString(), Normalizer.Form.NFC);
			String label = "names '" + abbreviate(name) + "'";
			if (o.has("nameUtf8NFC")) {
				check(label + " nameUtf8NFC", Arrays.equals(name.getBytes(StandardCharsets.UTF_8), hex(o, "nameUtf8NFC")));
			}
			String encName = names.encryptFilename(BaseEncoding.base64Url(), name, o.get("parentDirId").getAsString().getBytes(StandardCharsets.UTF_8)) + ".c9r";
			check(label + " encName", encName.equals(o.get("encName").getAsString()));
			boolean shouldShorten = encName.length() > threshold;
			if (o.has("shortened")) {
				String c9s = BaseEncoding.base64Url().encode(MessageDigest.getInstance("SHA-1").digest(encName.getBytes(StandardCharsets.UTF_8))) + ".c9s";
				check(label + " shortened " + o.get("shortened").getAsString(), shouldShorten && c9s.equals(o.get("shortened").getAsString()));
			} else {
				check(label + " not shortened (encName " + encName.length() + " chars ≤ 220)", !shouldShorten);
			}
		}

		// ---- file content
		i = 0;
		for (JsonElement e : v.getAsJsonArray("fileContent")) {
			String label = "fileContent[" + i++ + "]";
			try {
				checkFile(label, e.getAsJsonObject(), masterkey, cryptor);
			} catch (Exception ex) {
				check(label + " failed: " + ex, false);
			}
		}
	}

	private void checkFile(String label, JsonObject o, Masterkey masterkey, Cryptor cryptor) throws Exception {
		int size = o.get("plaintextSize").getAsInt();
		label += " (" + size + " B)";
		byte[] plaintext = new byte[size];
		for (int j = 0; j < size; j++) {
			plaintext[j] = (byte) (j % 251);
		}
		check(label + " plaintext rule is 'byte i = i mod 251'", o.get("plaintext").getAsString().replace(" ", "").equals("bytei=imod251"));
		byte[] headerNonce = hex(o, "headerNonce");
		byte[] contentKey = hex(o, "contentKey");
		byte[][] chunkNonces = hexList(o.getAsJsonArray("chunkNonces"));

		// Encrypt with cryptolib's own v2 header/content cryptors. Their public factory wraps the RNG in a reseeding
		// SHA1PRNG, so the package-private constructors are used with an RNG that replays the vector's nonces/key.
		ByteArrayOutputStream rngBytes = new ByteArrayOutputStream();
		rngBytes.write(headerNonce);
		rngBytes.write(contentKey);
		for (byte[] n : chunkNonces) {
			rngBytes.write(n);
		}
		ReplayRandom replay = new ReplayRandom(rngBytes.toByteArray());
		FileHeaderCryptor headerCryptor = construct("org.cryptomator.cryptolib.v2.FileHeaderCryptorImpl", new Class<?>[]{Masterkey.class, SecureRandom.class}, masterkey, replay);
		FileContentCryptor contentCryptor = construct("org.cryptomator.cryptolib.v2.FileContentCryptorImpl", new Class<?>[]{SecureRandom.class}, replay);
		FileHeader header = headerCryptor.create();
		ByteArrayOutputStream ct = new ByteArrayOutputStream();
		ct.write(bytes(headerCryptor.encryptHeader(header)));
		int chunkSize = contentCryptor.cleartextChunkSize();
		for (int off = 0, n = 0; off < size; off += chunkSize, n++) {
			ByteBuffer chunk = ByteBuffer.wrap(plaintext, off, Math.min(chunkSize, size - off));
			ct.write(bytes(contentCryptor.encryptChunk(chunk, n, header)));
		}
		byte[] built = ct.toByteArray();
		check(label + " chunk count == chunkNonces", (size + chunkSize - 1) / chunkSize == chunkNonces.length && replay.exhausted());
		check(label + " cryptolib-built ciphertext size == " + o.get("ciphertextSize").getAsInt(), built.length == o.get("ciphertextSize").getAsInt());
		check(label + " cryptolib-built ciphertext SHA-256", HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(built)).equals(o.get("ciphertextSha256").getAsString()));
		if (o.has("ciphertext")) {
			byte[] given = hex(o, "ciphertext");
			check(label + " cryptolib-built ciphertext == vector bytes", Arrays.equals(built, given));
		}

		// Decrypt (vector ciphertext if present, else the cryptolib-built one) through the public Cryptor API.
		byte[] input = o.has("ciphertext") ? hex(o, "ciphertext") : built;
		FileHeader decHeader = cryptor.fileHeaderCryptor().decryptHeader(ByteBuffer.wrap(input, 0, cryptor.fileHeaderCryptor().headerSize()));
		check(label + " header reserved == 0xFF×8", decHeader.getReserved() == -1L);
		ByteArrayOutputStream pt = new ByteArrayOutputStream();
		int hs = cryptor.fileHeaderCryptor().headerSize();
		int cs = cryptor.fileContentCryptor().ciphertextChunkSize();
		for (int off = hs, n = 0; off < input.length; off += cs, n++) {
			pt.write(bytes(cryptor.fileContentCryptor().decryptChunk(ByteBuffer.wrap(input, off, Math.min(cs, input.length - off)), n, decHeader, true)));
		}
		check(label + " Cryptor decrypts to the plaintext pattern" + (o.has("ciphertext") ? " (vector bytes)" : ""), Arrays.equals(pt.toByteArray(), plaintext));
	}

	// ---------------------------------------------------------------- helpers

	private void check(String what, boolean ok) {
		System.out.println((ok ? "✓ " : "✗ ") + what);
		if (ok) {
			passed++;
		} else {
			failed.add(what);
		}
	}

	@SuppressWarnings("unchecked")
	private static <T> T construct(String className, Class<?>[] types, Object... args) throws ReflectiveOperationException {
		Constructor<?> c = Class.forName(className).getDeclaredConstructor(types);
		c.setAccessible(true);
		return (T) c.newInstance(args);
	}

	private static byte[] bytes(ByteBuffer b) {
		byte[] r = new byte[b.remaining()];
		b.get(r);
		return r;
	}

	private static byte[] hex(JsonObject o, String field) {
		return HEX.parseHex(o.get(field).getAsString());
	}

	private static byte[][] hexList(JsonArray a) {
		byte[][] r = new byte[a.size()][];
		for (int j = 0; j < a.size(); j++) {
			r[j] = HEX.parseHex(a.get(j).getAsString());
		}
		return r;
	}

	private static byte[] concat(byte[] a, byte[] b) {
		byte[] r = Arrays.copyOf(a, a.length + b.length);
		System.arraycopy(b, 0, r, a.length, b.length);
		return r;
	}

	private static String abbreviate(String s) {
		return s.length() > 24 ? s.substring(0, 12) + "…(" + s.length() + " chars)" : s;
	}

	/** Hands out the given bytes in order; any read beyond them fails the check (exhausted() stays false). */
	private static final class ReplayRandom extends SecureRandom {
		private final byte[] data;
		private int pos;
		private boolean overrun;

		ReplayRandom(byte[] data) {
			this.data = data;
		}

		@Override
		public synchronized void nextBytes(byte[] bytes) {
			if (pos + bytes.length > data.length) {
				overrun = true;
				Arrays.fill(bytes, (byte) 0);
				return;
			}
			System.arraycopy(data, pos, bytes, 0, bytes.length);
			pos += bytes.length;
		}

		boolean exhausted() {
			return !overrun && pos == data.length;
		}
	}
}
