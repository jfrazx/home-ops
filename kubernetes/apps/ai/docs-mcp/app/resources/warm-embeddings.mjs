// Block until the embedding model is resident in Ollama, or give up loudly.
//
// Ollama runs with OLLAMA_MAX_LOADED_MODELS=1, so any chat request evicts the
// embedding model. Reloading embeddinggemma:300m onto the Intel iGPU takes
// ~2.5 minutes, and docs-mcp-server has no knob to extend its own embedding
// timeout -- it just logs "the embedding service appears unreachable" and
// drops the page. A scrape that starts cold therefore indexes almost nothing
// while still reporting success.
//
// One oversized request up front absorbs that load. OLLAMA_KEEP_ALIVE is 2h,
// comfortably longer than a sync run, so every embedding after this one is
// served warm (~200ms) from memory.

const base = process.env.OPENAI_API_BASE;
const key = process.env.OPENAI_API_KEY ?? "";

// DOCS_MCP_EMBEDDING_MODEL is "<provider>:<model>", and the model half may
// itself contain colons ("embeddinggemma:300m"), so split on the first only.
const spec = process.env.DOCS_MCP_EMBEDDING_MODEL ?? "";
const model = spec.slice(spec.indexOf(":") + 1);

if (!base || !model) {
  console.error(
    "[warm] OPENAI_API_BASE and DOCS_MCP_EMBEDDING_MODEL must both be set",
  );
  process.exit(1);
}

// Per-attempt ceiling well above the ~150s cold load measured on this cluster,
// with enough attempts to cover a concurrent chat request holding the GPU.
const ATTEMPT_TIMEOUT_MS = 300_000;
const ATTEMPTS = 3;
const RETRY_DELAY_MS = 15_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
  const startedAt = Date.now();

  try {
    const response = await fetch(new URL("embeddings", `${base}/`), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({ model, input: "docs-mcp embedding warmup" }),
      signal: AbortSignal.timeout(ATTEMPT_TIMEOUT_MS),
    });

    const elapsed = Math.round((Date.now() - startedAt) / 1000);

    if (response.ok) {
      console.log(`[warm] ${model} ready after ${elapsed}s`);
      process.exit(0);
    }

    // Drain the body so the socket is released before the next attempt.
    const detail = (await response.text()).slice(0, 200);
    console.error(
      `[warm] attempt ${attempt}/${ATTEMPTS} got HTTP ${response.status} after ${elapsed}s: ${detail}`,
    );
  } catch (error) {
    const elapsed = Math.round((Date.now() - startedAt) / 1000);
    console.error(
      `[warm] attempt ${attempt}/${ATTEMPTS} failed after ${elapsed}s: ${error.name}: ${error.message}`,
    );
  }

  if (attempt < ATTEMPTS) await sleep(RETRY_DELAY_MS);
}

console.error(`[warm] ${model} never became ready; refusing to scrape cold`);
process.exit(1);
