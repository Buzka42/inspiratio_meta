// Fixed guardrails. They live in code (isCrisis, withMedicalLines, dataModeProblem); the spec can never change
// them, and SPEC.md shows this text read-only. GUARDRAIL_KEYS are the names the spec validator always refuses.
import { NOT_MEDICAL_ADVICE, REFERRAL_TEXT } from "../safety.js";

export const GUARDRAILS = Object.freeze({
  crisis: REFERRAL_TEXT,
  medical: NOT_MEDICAL_ADVICE,
  data: "Personal data goes only to the providers this deployment's data mode allows. " +
    "Your settings can narrow that, never widen it.",
});

export const GUARDRAIL_KEYS = Object.freeze([
  "guardrails", "crisis", "disclaimer", "medical_line", "data_mode", "model", "url", "provider_url",
]);
