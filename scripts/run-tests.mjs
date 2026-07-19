#!/usr/bin/env node
import { runTestSuite } from "./lib/test-runner.mjs";

const args = process.argv.slice(2);

try {
  if (args.length > 1) throw new Error("usage: node scripts/run-tests.mjs [affected|release|quick|stage|full]");
  runTestSuite({ mode: args[0] ?? "affected" });
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
}
