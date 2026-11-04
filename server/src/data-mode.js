// Data rule (docs/DESIGN.md): real owner data goes only to providers that do not
// train on prompts (Meta standard tier, Nebius with the training opt-out, the owner's own hosts).
// Contributor models are refused on every path under every DATA_MODE (owner decision 2026-11-03).
// DATA_MODE=owner_real (the default) also refuses the free OpenCode/OpenRouter test providers on the council,
// reply and memory paths. DATA_MODE=synthetic allows the test providers for demos.
// DATA_MODE=owner_any (owner consent, 2026-10-25): the owner's own real data may go to every provider,
// free tiers included, but never a contributor model. The owner accepted that free tiers may train on or keep prompts.
// Refusals name variables, never values.

export const OWNER_REAL = "owner_real";
export const SYNTHETIC = "synthetic";
export const OWNER_ANY = "owner_any";
export const DATA_MODES = [OWNER_REAL, SYNTHETIC, OWNER_ANY];

// The owner's own hosts (the Hermes `illunis` profile on the owner's PC, src/assistants/hermes.js):
// allowed under owner_real, since prompts never leave the owner's machine.
export const OWNER_HOSTS = new Set(["hermes"]);

// Free test providers that may train on, or keep, prompts.
export const TEST_PROVIDERS = new Set(["opencode", "opencode_poc", "openrouter_poc", "poc_opencode_nebius"]);

export const isContributorModel = (model) => /contributor/i.test(String(model ?? ""));
// Contributor models are refused everywhere, whatever DATA_MODE says.
export const contributorRefused = (env, model) => isContributorModel(model);
// OpenRouter free tiers end in ":free"; OpenCode Zen free ids end in "-free".
export const isFreeTierModel = (model) => /(?::|-)free$/i.test(String(model ?? "").trim());

// Unset or empty means owner_real; an unknown value is refused rather than guessed.
export function dataMode(env = {}) {
  const v = env.DATA_MODE;
  if (v === undefined || v === "") return OWNER_REAL;
  return DATA_MODES.includes(v) ? v : null;
}

// Returns a refusal reason or null. `provider` is the switch value, `model` the id about to be used.
export function dataModeProblem(env = {}, { provider, model, role = "model" } = {}) {
  const mode = dataMode(env);
  if (!mode) return `DATA_MODE unknown: use ${DATA_MODES.join(", ")}`;
  if (isContributorModel(model)) return `contributor model refused for ${role} under every DATA_MODE`;
  if (mode === SYNTHETIC || mode === OWNER_ANY) return null;
  if (provider && TEST_PROVIDERS.has(provider)) return `${provider} refused for ${role} under DATA_MODE=${OWNER_REAL}`;
  if (isFreeTierModel(model)) return `free-tier model refused for ${role} under DATA_MODE=${OWNER_REAL}`;
  return null;
}
