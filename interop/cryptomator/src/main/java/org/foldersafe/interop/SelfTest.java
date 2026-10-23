package org.foldersafe.interop;

import org.cryptomator.cryptofs.CryptoFileSystemProvider;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileSystem;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.stream.Stream;

/** create → dump → compare, then write → dump → compare, on a generated tree in a temp directory. */
final class SelfTest {

	private static final String PASSWORD = "selftest-password-ü";

	private SelfTest() {
	}

	static void run() throws IOException {
		Path tmp = Files.createTempDirectory("cryptomator-interop-");
		Path src = tmp.resolve("src");
		Path vault = tmp.resolve("vault");
		Random rnd = new Random(42);

		// --- source tree (names must fit the host file system: APFS allows 255 UTF-8 bytes) ---
		Files.createDirectories(src.resolve("a/b/c"));
		Files.createDirectories(src.resolve("emptydir"));
		Files.write(src.resolve("empty.txt"), new byte[0]);
		Files.write(src.resolve("one.bin"), randomBytes(rnd, 1));
		Files.write(src.resolve("exact-32768.bin"), randomBytes(rnd, 32768));
		Files.write(src.resolve("a/big-100000.bin"), randomBytes(rnd, 100000));
		Files.writeString(src.resolve("a/b/c/deep.txt"), "three levels deep\n");
		Files.writeString(src.resolve("中文文件名-😀.txt"), "unicode name\n");
		Files.writeString(src.resolve("café-nfd.txt"), "stored with an NFD name on the host\n"); // must come out NFC
		Files.writeString(src.resolve("L".repeat(200) + ".txt"), "200 chars: encrypted name > 220 → .c9s\n");
		Files.createSymbolicLink(src.resolve("link-to-deep"), Path.of("a/b/c/deep.txt"));
		Files.createSymbolicLink(src.resolve("a/dangling-link"), Path.of("../does/not/exist"));

		System.err.println("selftest: working in " + tmp);
		VaultIO.create(vault, PASSWORD, src);

		// --- a 300+ character name cannot exist on APFS, so write it straight into the vault ---
		String longName = "长".repeat(10) + "X".repeat(300) + ".txt";
		byte[] longContent = "310+ char name\n".getBytes(StandardCharsets.UTF_8);
		try (FileSystem fs = CryptoFileSystemProvider.newFileSystem(vault, VaultIO.properties(vault, PASSWORD, false))) {
			Files.write(fs.getPath("/a/b", longName), longContent);
		}

		List<VaultIO.Entry> expected = new ArrayList<>(VaultIO.dump(src));
		expected.add(new VaultIO.Entry("/a/b/" + longName, "file", longContent.length, sha256Hex(longContent), null));
		expected.sort(Comparator.comparing(VaultIO.Entry::path));
		List<String> failures = new ArrayList<>(compare("after create", expected, VaultIO.dumpVault(vault, PASSWORD)));

		// --- write: overwrite one file, add new ones ---
		Path src2 = tmp.resolve("src2");
		Files.createDirectories(src2.resolve("a/new-dir"));
		Files.write(src2.resolve("one.bin"), randomBytes(rnd, 40000));
		Files.writeString(src2.resolve("a/new-dir/added.txt"), "added by write\n");
		VaultIO.write(vault, PASSWORD, src2);
		List<VaultIO.Entry> expected2 = new ArrayList<>(expected);
		List<VaultIO.Entry> overlay = VaultIO.dump(src2);
		expected2.removeIf(e -> overlay.stream().anyMatch(o -> o.path().equals(e.path())));
		expected2.addAll(overlay);
		expected2.sort(Comparator.comparing(VaultIO.Entry::path));
		failures.addAll(compare("after write", expected2, VaultIO.dumpVault(vault, PASSWORD)));

		// --- ciphertext shape checks ---
		long c9s;
		try (Stream<Path> s = Files.walk(vault.resolve("d"))) {
			c9s = s.filter(p -> p.getFileName().toString().endsWith(".c9s") && Files.isDirectory(p)).count();
		}
		if (c9s != 2) {
			failures.add("expected 2 shortened (.c9s) nodes, found " + c9s);
		}

		if (failures.isEmpty()) {
			deleteRecursively(tmp);
			System.out.println("OK");
		} else {
			failures.forEach(f -> System.err.println("FAIL: " + f));
			throw new IOException("selftest failed (" + failures.size() + " problems); files kept in " + tmp);
		}
	}

	private static List<String> compare(String stage, List<VaultIO.Entry> expected, List<VaultIO.Entry> actual) {
		List<String> problems = new ArrayList<>();
		for (VaultIO.Entry e : expected) {
			if (!actual.contains(e)) {
				problems.add(stage + ": missing or different: " + e);
			}
		}
		for (VaultIO.Entry a : actual) {
			if (!expected.contains(a)) {
				problems.add(stage + ": unexpected: " + a);
			}
		}
		return problems;
	}

	private static byte[] randomBytes(Random rnd, int n) {
		byte[] b = new byte[n];
		rnd.nextBytes(b);
		return b;
	}

	private static String sha256Hex(byte[] data) {
		try {
			return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256").digest(data));
		} catch (java.security.NoSuchAlgorithmException e) {
			throw new IllegalStateException(e);
		}
	}

	private static void deleteRecursively(Path root) throws IOException {
		try (Stream<Path> s = Files.walk(root)) {
			for (Path p : s.sorted(Comparator.reverseOrder()).toList()) {
				Files.delete(p);
			}
		}
	}
}
