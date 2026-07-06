// ponytail: smallest runnable check for extractDateCandidates (the one
// non-trivial parser added in Phase 2). Not wired into any build step —
// run manually: npx tsc lib/mcpTools.selftest.ts --outDir /tmp/mcptest --module commonjs --target es2020 --skipLibCheck && node /tmp/mcptest/mcpTools.selftest.js
// (also exercises extractDateCandidates via mcpTools.ts's export, so it
// transitively compiles that whole file.)
import { extractDateCandidates } from "./mcpTools";

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(`FAIL: ${msg}`);
}

const body =
  "Hi team. Please send the signed contract by March 5th, 2026 at the latest. " +
  "Also confirm the meeting by Friday. No dates here otherwise, just chatting.";

const candidates = extractDateCandidates(body);
assert(candidates.length > 0, "should find at least one candidate");
assert(
  candidates.some((c) => c.match.toLowerCase().includes("march 5th")),
  "should catch 'by March 5th, 2026'"
);
assert(
  candidates.some((c) => c.confidence === "high"),
  "the 'by <month day>' pattern should be high confidence"
);
assert(
  candidates.some((c) => /friday/i.test(c.match)),
  "should catch 'by Friday'"
);
assert(
  candidates.every((c) => c.context_sentence.length > 0),
  "every candidate should have a non-empty context sentence"
);

const noDates = extractDateCandidates("Thanks for the update, sounds good!");
assert(noDates.length === 0, "plain text with no dates should yield no candidates");

console.log("mcpTools.selftest: all assertions passed");
