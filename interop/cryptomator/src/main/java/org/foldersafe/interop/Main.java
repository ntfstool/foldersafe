package org.foldersafe.interop;

import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;

/**
 * Test-only interop harness around Cryptomator's cryptofs. See README.md.
 * <p>
 * stdout carries only the JSON of {@code dump}, "OK" of {@code selftest} and the ✓/✗ lines of {@code verify-vectors}; everything else goes to stderr.
 */
public final class Main {

	private static final String USAGE = """
			usage:
			  create   --vault DIR --password PW --source SRC   new vault (format 8, SIV_GCM), then copy SRC into it
			  dump     --vault DIR --password PW                print {"entries":[...]} as JSON on stdout
			  write    --vault DIR --password PW --source SRC   copy SRC into an existing vault (overwrite files)
			  selftest                                          create/dump/compare a generated tree in a temp dir
			  verify-vectors --file F                           check FolderSafe test vectors (L1) against cryptolib/cryptofs
			""";

	public static void main(String[] args) {
		if (args.length == 0) {
			System.err.print(USAGE);
			System.exit(2);
		}
		try {
			Map<String, String> opts = parseOptions(args);
			switch (args[0]) {
				case "create" -> VaultIO.create(path(opts, "--vault"), required(opts, "--password"), path(opts, "--source"));
				case "dump" -> System.out.println(VaultIO.toJson(VaultIO.dumpVault(path(opts, "--vault"), required(opts, "--password"))));
				case "write" -> VaultIO.write(path(opts, "--vault"), required(opts, "--password"), path(opts, "--source"));
				case "selftest" -> SelfTest.run();
				case "verify-vectors" -> VectorCheck.run(path(opts, "--file"));
				default -> throw new UsageException("unknown command: " + args[0]);
			}
			System.out.flush();
			System.exit(0);
		} catch (UsageException e) {
			System.err.println("error: " + e.getMessage());
			System.err.print(USAGE);
			System.exit(2);
		} catch (org.cryptomator.cryptolib.api.InvalidPassphraseException e) {
			System.err.println("error: wrong password (masterkey AES-KW unwrap failed)");
			System.exit(1);
		} catch (Throwable e) {
			System.err.println("error: " + e);
			for (Throwable c = e.getCause(); c != null; c = c.getCause()) {
				System.err.println("  caused by: " + c);
			}
			if (System.getenv("INTEROP_DEBUG") != null) {
				e.printStackTrace();
			}
			System.exit(1);
		}
	}

	private static Map<String, String> parseOptions(String[] args) throws UsageException {
		Map<String, String> opts = new HashMap<>();
		for (int i = 1; i < args.length; i++) {
			if (!args[i].startsWith("--") || i + 1 >= args.length) {
				throw new UsageException("bad argument: " + args[i]);
			}
			opts.put(args[i], args[++i]);
		}
		return opts;
	}

	private static String required(Map<String, String> opts, String name) throws UsageException {
		String v = opts.get(name);
		if (v == null) {
			throw new UsageException("missing " + name);
		}
		return v;
	}

	private static Path path(Map<String, String> opts, String name) throws UsageException {
		return Path.of(required(opts, name)).toAbsolutePath().normalize();
	}

	static final class UsageException extends Exception {
		UsageException(String msg) {
			super(msg);
		}
	}
}
