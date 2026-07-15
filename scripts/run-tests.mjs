#!/usr/bin/env node
import { runTestSuite } from "./lib/test-runner.mjs";

const args = process.argv.slice(2);

try {
  if (args.length > 1) throw new Error("usage: node scripts/run-tests.mjs [quick|extended|extended-only|release|release-only]");
  runTestSuite({ mode: args[0] ?? "quick" });
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
}
