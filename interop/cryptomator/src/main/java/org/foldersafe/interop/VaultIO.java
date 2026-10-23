package org.foldersafe.interop;

import org.cryptomator.cryptofs.CryptoFileSystemProperties;
import org.cryptomator.cryptofs.CryptoFileSystemProperties.FileSystemFlags;
import org.cryptomator.cryptofs.CryptoFileSystemProvider;
import org.cryptomator.cryptolib.api.CryptorProvider;
import org.cryptomator.cryptolib.api.Masterkey;
import org.cryptomator.cryptolib.api.MasterkeyLoader;
import org.cryptomator.cryptolib.api.MasterkeyLoadingFailedException;
import org.cryptomator.cryptolib.common.MasterkeyFileAccess;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.file.DirectoryStream;
import java.nio.file.FileSystem;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.stream.Stream;

/** Vault operations on top of cryptofs, plus a provider-independent tree dump. */
final class VaultIO {

	static final String MASTERKEY_FILE = "masterkey.cryptomator";
	static final String VAULT_CONFIG_FILE = "vault.cryptomator";
	static final URI KEY_ID = URI.create("masterkeyfile:" + MASTERKEY_FILE);
	private static final LinkOption NOFOLLOW = LinkOption.NOFOLLOW_LINKS;

	/** One node of a cleartext tree. size/sha256 only for files, target only for symlinks. */
	record Entry(String path, String type, long size, String sha256, String target) {
		static Entry dir(String path) {
			return new Entry(path, "dir", -1, null, null);
		}
	}

	private VaultIO() {
	}

	// ---------------------------------------------------------------- commands

	static void create(Path vault, String password, Path source) throws IOException {
		requireDirectory(source, "source");
		if (Files.exists(vault, NOFOLLOW)) {
			requireDirectory(vault, "vault");
			try (Stream<Path> s = Files.list(vault)) {
				if (s.findAny().isPresent()) {
					throw new IOException("vault directory is not empty: " + vault);
				}
			}
		} else {
			Files.createDirectories(vault);
		}
		SecureRandom csprng = new SecureRandom();
		try (Masterkey key = Masterkey.generate(csprng)) {
			// library defaults: version 999, scrypt N = 2^15, r = 8, empty pepper (same as the Cryptomator desktop app)
			new MasterkeyFileAccess(new byte[0], csprng).persist(key, vault.resolve(MASTERKEY_FILE), password);
		}
		CryptoFileSystemProperties props = properties(vault, password, false);
		CryptoFileSystemProvider.initialize(vault, props, KEY_ID);
		try (FileSystem fs = CryptoFileSystemProvider.newFileSystem(vault, props)) {
			copyTree(source, fs.getPath("/"));
		}
	}

	static void write(Path vault, String password, Path source) throws IOException {
		requireDirectory(source, "source");
		requireVault(vault);
		try (FileSystem fs = CryptoFileSystemProvider.newFileSystem(vault, properties(vault, password, false))) {
			copyTree(source, fs.getPath("/"));
		}
	}

	static List<Entry> dumpVault(Path vault, String password) throws IOException {
		requireVault(vault);
		List<Entry> entries;
		try (FileSystem fs = CryptoFileSystemProvider.newFileSystem(vault, properties(vault, password, true))) {
			entries = dump(fs.getPath("/"));
		}
		checkCiphertextTree(vault, entries);
		return entries;
	}

	// ---------------------------------------------------------------- cryptofs setup

	static CryptoFileSystemProperties properties(Path vault, String password, boolean readonly) {
		var builder = CryptoFileSystemProperties.cryptoFileSystemProperties() //
				.withKeyLoader(keyLoader(vault, password)) //
				.withCipherCombo(CryptorProvider.Scheme.SIV_GCM) //
				.withFilesystemEventConsumer(event -> System.err.println("cryptofs event: " + event));
		if (readonly) {
			builder.withFlags(FileSystemFlags.READONLY);
		}
		return builder.build();
	}

	/** Resolves {@code masterkeyfile:<name>} relative to the vault; runs scrypt only once per invocation. */
	static MasterkeyLoader keyLoader(Path vault, String password) {
		MasterkeyFileAccess access = new MasterkeyFileAccess(new byte[0], new SecureRandom());
		Masterkey[] cached = new Masterkey[1];
		return keyId -> {
			if (!"masterkeyfile".equals(keyId.getScheme())) {
				throw new MasterkeyLoadingFailedException("unsupported key id: " + keyId);
			}
			synchronized (cached) {
				if (cached[0] == null) {
					cached[0] = access.load(vault.resolve(keyId.getSchemeSpecificPart()), password);
				}
				return cached[0].copy(); // cryptofs destroys the key it gets
			}
		};
	}

	// ---------------------------------------------------------------- tree copy / dump

	/** Copies the children of {@code src} into {@code dst}: files (overwriting), dirs, symlinks (not followed). */
	static void copyTree(Path src, Path dst) throws IOException {
		for (Path child : sortedChildren(src)) {
			String name = child.getFileName().toString();
			Path target = dst.resolve(name);
			BasicFileAttributes attrs = Files.readAttributes(child, BasicFileAttributes.class, NOFOLLOW);
			if (attrs.isSymbolicLink()) {
				String linkTarget = Files.readSymbolicLink(child).toString();
				deleteIfFileOrLink(target);
				Files.createSymbolicLink(target, dst.getFileSystem().getPath(linkTarget));
			} else if (attrs.isDirectory()) {
				if (!Files.isDirectory(target, NOFOLLOW)) {
					deleteIfFileOrLink(target);
					Files.createDirectory(target);
				}
				copyTree(child, target);
			} else if (attrs.isRegularFile()) {
				deleteIfFileOrLink(target);
				Files.copy(child, target, StandardCopyOption.REPLACE_EXISTING);
			} else {
				System.err.println("warning: skipping special file " + child);
			}
		}
	}

	/** Lists everything below {@code root} (root excluded), sorted by NFC path. Works on any FileSystem. */
	static List<Entry> dump(Path root) throws IOException {
		List<Entry> all = new ArrayList<>();
		dumpInto(root, "", all);
		all.sort(Comparator.comparing(Entry::path));
		// cryptofs can list one name twice (e.g. while resolving a sync conflict, or two .c9s nodes with the same name)
		List<Entry> out = new ArrayList<>();
		for (Entry e : all) {
			if (!out.isEmpty() && out.getLast().path().equals(e.path())) {
				System.err.println("warning: path listed more than once, keeping the first: " + e.path());
			} else {
				out.add(e);
			}
		}
		return out;
	}

	private static void dumpInto(Path dir, String prefix, List<Entry> out) throws IOException {
		for (Path child : sortedChildren(dir)) {
			String rawName = child.getFileName().toString();
			String name = Normalizer.normalize(rawName, Normalizer.Form.NFC);
			if (!name.equals(rawName)) {
				System.err.println("note: name is not NFC: " + prefix + "/" + rawName);
			}
			String path = prefix + "/" + name;
			BasicFileAttributes attrs = Files.readAttributes(child, BasicFileAttributes.class, NOFOLLOW);
			if (attrs.isSymbolicLink()) {
				out.add(new Entry(path, "symlink", -1, null, Files.readSymbolicLink(child).toString()));
			} else if (attrs.isDirectory()) {
				out.add(Entry.dir(path));
				dumpInto(child, path, out);
			} else if (attrs.isRegularFile()) {
				out.add(fileEntry(path, child, attrs.size()));
			} else {
				System.err.println("warning: skipping special file " + path);
			}
		}
	}

	private static Entry fileEntry(String path, Path file, long reportedSize) throws IOException {
		MessageDigest sha256;
		try {
			sha256 = MessageDigest.getInstance("SHA-256");
		} catch (NoSuchAlgorithmException e) {
			throw new IllegalStateException(e);
		}
		long size = 0;
		byte[] buf = new byte[64 * 1024];
		try (InputStream in = Files.newInputStream(file)) {
			for (int n; (n = in.read(buf)) != -1; ) {
				sha256.update(buf, 0, n);
				size += n;
			}
		}
		if (size != reportedSize) {
			System.err.println("warning: " + path + ": attribute size " + reportedSize + " != bytes read " + size);
		}
		return new Entry(path, "file", size, HexFormat.of().formatHex(sha256.digest()), null);
	}

	// ---------------------------------------------------------------- ciphertext sanity checks (stderr only)

	/** Reports root entries cryptofs does not use and ciphertext nodes that did not show up in the cleartext listing. */
	private static void checkCiphertextTree(Path vault, List<Entry> entries) throws IOException {
		for (Path p : sortedChildren(vault)) {
			String n = p.getFileName().toString();
			if (!Set.of(VAULT_CONFIG_FILE, MASTERKEY_FILE, "d").contains(n) && !n.endsWith(".bkup")) {
				System.err.println("note: vault root entry not used by cryptofs: " + n);
			}
		}
		long nodes = 0;
		long contentDirs = 0;
		Path d = vault.resolve("d");
		for (Path l1 : sortedChildren(d)) {
			for (Path contentDir : sortedChildren(l1)) {
				contentDirs++;
				for (Path node : sortedChildren(contentDir)) {
					String n = node.getFileName().toString();
					if (n.equals("dirid.c9r")) {
						continue;
					}
					if (n.endsWith(".c9r") || n.endsWith(".c9s")) {
						nodes++;
					} else {
						System.err.println("note: ignored non-c9r/c9s entry: " + vault.relativize(node));
					}
				}
			}
		}
		long dirs = entries.stream().filter(e -> e.type().equals("dir")).count();
		if (nodes != entries.size()) {
			System.err.println("warning: " + nodes + " ciphertext nodes on disk but " + entries.size()
					+ " cleartext entries listed (undecryptable, broken or hidden nodes?)");
		}
		if (contentDirs != dirs + 1) {
			System.err.println("warning: " + contentDirs + " content dirs under d/ but " + (dirs + 1)
					+ " directories incl. root (orphaned or missing dirs?)");
		}
	}

	// ---------------------------------------------------------------- helpers

	static List<Path> sortedChildren(Path dir) throws IOException {
		List<Path> children = new ArrayList<>();
		try (DirectoryStream<Path> ds = Files.newDirectoryStream(dir)) {
			ds.forEach(children::add);
		}
		children.sort(Comparator.comparing(p -> p.getFileName().toString()));
		return children;
	}

	private static void deleteIfFileOrLink(Path p) throws IOException {
		if (Files.exists(p, NOFOLLOW) && !Files.isDirectory(p, NOFOLLOW)) {
			Files.delete(p);
		} else if (Files.isDirectory(p, NOFOLLOW)) {
			try (Stream<Path> s = Files.list(p)) {
				if (s.findAny().isPresent()) {
					throw new IOException("cannot replace non-empty directory: " + p);
				}
			}
			Files.delete(p);
		}
	}

	private static void requireDirectory(Path p, String what) throws IOException {
		if (!Files.isDirectory(p)) {
			throw new IOException(what + " is not a directory: " + p);
		}
	}

	private static void requireVault(Path vault) throws IOException {
		if (!Files.isRegularFile(vault.resolve(VAULT_CONFIG_FILE))) {
			throw new IOException("not a vault (no " + VAULT_CONFIG_FILE + "): " + vault);
		}
	}

	static String toJson(List<Entry> entries) {
		StringBuilder sb = new StringBuilder("{\"entries\":[");
		for (int i = 0; i < entries.size(); i++) {
			Entry e = entries.get(i);
			sb.append(i == 0 ? "\n" : ",\n").append("{\"path\":").append(quote(e.path())).append(",\"type\":").append(quote(e.type()));
			switch (e.type()) {
				case "file" -> sb.append(",\"size\":").append(e.size()).append(",\"sha256\":").append(quote(e.sha256()));
				case "symlink" -> sb.append(",\"target\":").append(quote(e.target()));
				default -> {
				}
			}
			sb.append('}');
		}
		return sb.append("\n]}").toString();
	}

	private static String quote(String s) {
		StringBuilder sb = new StringBuilder("\"");
		for (char c : s.toCharArray()) {
			switch (c) {
				case '"' -> sb.append("\\\"");
				case '\\' -> sb.append("\\\\");
				case '\n' -> sb.append("\\n");
				case '\r' -> sb.append("\\r");
				case '\t' -> sb.append("\\t");
				default -> {
					if (c < 0x20) {
						sb.append(String.format("\\u%04x", (int) c));
					} else {
						sb.append(c);
					}
				}
			}
		}
		return sb.append('"').toString();
	}
}
