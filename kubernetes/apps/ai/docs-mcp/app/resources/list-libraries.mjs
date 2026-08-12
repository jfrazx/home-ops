// Flatten `docs-mcp-server list --output json` into
// "<library>\x1f<version>\x1f<sourceUrl>" lines, one per indexed version, so
// sync.sh can iterate them without a JSON parser (the image ships no jq).
//
// Reads the JSON on stdin. An unversioned library reports version "", which
// sync.sh passes through as "no --version flag".
//
// The field separator is the ASCII unit separator, not a tab: `read` treats
// tab as IFS whitespace and collapses runs of it, so an empty version field
// would silently shift sourceUrl into the version column.
const SEP = "\x1f";

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const raw = Buffer.concat(chunks).toString("utf8").trim();

if (!raw) {
  console.error("[list] no output from the list command");
  process.exit(1);
}

let libraries;
try {
  libraries = JSON.parse(raw);
} catch (error) {
  console.error(`[list] could not parse list output: ${error.message}`);
  process.exit(1);
}

if (!Array.isArray(libraries)) {
  console.error("[list] expected a JSON array of libraries");
  process.exit(1);
}

// A separator or newline in any field would split into a bogus record
// downstream. Nothing GitHub-derived contains one, so treat it as corruption
// and skip rather than emit a record sync.sh would misread.
const isClean = (value) => !/[\x1f\r\n]/.test(value);

let emitted = 0;

for (const library of libraries) {
  const name = library?.name;
  if (typeof name !== "string" || !name || !isClean(name)) continue;

  for (const version of library?.versions ?? []) {
    const label = typeof version?.version === "string" ? version.version : "";
    // sourceUrl is absent for libraries indexed from a local path; those can
    // still be refreshed, they just have no URL to fall back to.
    const url = typeof version?.sourceUrl === "string" ? version.sourceUrl : "";
    if (!isClean(label) || !isClean(url)) continue;

    console.log(`${name}${SEP}${label}${SEP}${url}`);
    emitted++;
  }
}

if (emitted === 0) console.error("[list] the index is empty");
