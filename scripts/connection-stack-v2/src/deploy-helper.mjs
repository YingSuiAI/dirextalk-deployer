import {
  createHash,
} from "node:crypto";
import {
  lstatSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import {
  dirname,
  join,
  relative,
} from "node:path";
import {
  fileURLToPath,
  pathToFileURL,
} from "node:url";

import {
  validateBootstrapIdentity,
} from "./command-contract.mjs";
import {
  buildConnectionRegistrationManifest,
  validateConnectionStackDeployRequest,
} from "./registration-contract.mjs";

export function connectionStackTemplateDigest(templatePath) {
  return `sha256:${createHash("sha256").update(readFileSync(localPath(templatePath))).digest("hex")}`;
}

export function connectionStackSourceTreeDigest(stackDirectory) {
  const root = localPath(stackDirectory);
  const files = [];
  collectSourceFiles(root, root, files);
  const hash = createHash("sha256");
  for (const file of files.sort()) {
    hash.update(file, "utf8");
    hash.update("\0", "utf8");
    hash.update(readFileSync(join(root, file)));
    hash.update("\0", "utf8");
  }
  return `sha256:${hash.digest("hex")}`;
}

function collectSourceFiles(root, directory, files) {
  for (const entry of readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.name === "node_modules" || entry.name === ".aws-sam") continue;
    const path = join(directory, entry.name);
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error("Connection Stack source tree must not contain symbolic links");
    if (stat.isDirectory()) {
      collectSourceFiles(root, path, files);
      continue;
    }
    if (!stat.isFile()) throw new Error("Connection Stack source tree contains an unsupported entry");
    files.push(relative(root, path).replace(/\\/g, "/"));
  }
}

function localPath(value) {
  return value instanceof URL ? fileURLToPath(value) : String(value);
}

export function readJSON(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

export function validateConnectionStackDeploymentRequestFile(requestPath, templatePath) {
  const templateFile = localPath(templatePath);
  return validateConnectionStackDeployRequest(readJSON(requestPath), {
    templateSha256: connectionStackTemplateDigest(templateFile),
    sourceTreeSha256: connectionStackSourceTreeDigest(dirname(templateFile)),
  });
}

export function validateConnectionStackBootstrapIdentityFile(identityPath) {
  return validateBootstrapIdentity(readJSON(identityPath));
}

export function validateConnectionStackArtifactBucket(publicAccessBlock, encryption, location, expectedRegion) {
  const configuration = publicAccessBlock?.PublicAccessBlockConfiguration;
  const allPublicAccessBlocksEnabled = configuration
    && configuration.BlockPublicAcls === true
    && configuration.IgnorePublicAcls === true
    && configuration.BlockPublicPolicy === true
    && configuration.RestrictPublicBuckets === true;
  if (!allPublicAccessBlocksEnabled) {
    throw new Error("Connection Stack artifact bucket must enable every S3 public-access block");
  }
  const rules = encryption?.ServerSideEncryptionConfiguration?.Rules;
  const algorithm = Array.isArray(rules)
    ? rules.find((rule) => typeof rule?.ApplyServerSideEncryptionByDefault?.SSEAlgorithm === "string")?.ApplyServerSideEncryptionByDefault?.SSEAlgorithm
    : undefined;
  if (algorithm !== "AES256" && algorithm !== "aws:kms") {
    throw new Error("Connection Stack artifact bucket must enable default server-side encryption");
  }
  const normalizedRegion = location?.LocationConstraint === null || location?.LocationConstraint === ""
    ? "us-east-1"
    : location?.LocationConstraint === "EU"
      ? "eu-west-1"
      : location?.LocationConstraint;
  if (normalizedRegion !== expectedRegion) {
    throw new Error("Connection Stack artifact bucket must be in the requested Stack region");
  }
}

export function validateConnectionStackArtifactBucketFiles(publicAccessBlockPath, encryptionPath, locationPath, expectedRegion) {
  return validateConnectionStackArtifactBucket(
    readJSON(publicAccessBlockPath),
    readJSON(encryptionPath),
    readJSON(locationPath),
    expectedRegion,
  );
}

export function buildConnectionStackRegistrationManifest(requestPath, identityPath, stackDescriptionPath) {
  return buildConnectionRegistrationManifest(
    readJSON(requestPath),
    validateConnectionStackBootstrapIdentityFile(identityPath),
    readJSON(stackDescriptionPath),
  );
}

function usage() {
  throw new Error("usage: deploy-helper.mjs <validate-request|validate-identity|validate-artifact-bucket|build-manifest> <files...>");
}

function main(args) {
  const [command, ...rest] = args;
  switch (command) {
    case "validate-request":
      if (rest.length !== 2) usage();
      validateConnectionStackDeploymentRequestFile(rest[0], rest[1]);
      return;
    case "validate-identity":
      if (rest.length !== 1) usage();
      validateConnectionStackBootstrapIdentityFile(rest[0]);
      return;
    case "validate-artifact-bucket":
      if (rest.length !== 4) usage();
      validateConnectionStackArtifactBucketFiles(rest[0], rest[1], rest[2], rest[3]);
      return;
    case "build-manifest":
      if (rest.length !== 3) usage();
      process.stdout.write(`${JSON.stringify(buildConnectionStackRegistrationManifest(rest[0], rest[1], rest[2]))}\n`);
      return;
    default:
      usage();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error?.message || "connection stack deployment helper failed"}\n`);
    process.exitCode = 1;
  }
}
