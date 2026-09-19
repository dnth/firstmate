// Judge profile parser for the Firstmate OMP compact adviser.
// Ported verbatim from upstream compact-adviser packages/pi-extension/src/profile.ts
// at pinned commit b2a27b59ce86af4dc8fb5141e169bfbed1e68cee.

/** A bounded, data-only override. Missing or empty settings preserve shipped defaults. */
export interface ProfileQuestions {
  done: {
    type: "choice";
    instructions: string;
    criteria: { finished: string; not_finished: string; unclear: string };
  };
  shape: {
    type: "choice";
    instructions: string;
    criteria: { hands_on: string; coordinating: string; unclear: string };
  };
}

export interface JudgeProfile {
  version: 1;
  coordinationWeight: number;
  floors: [number, number][];
  questions?: ProfileQuestions;
}

function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function keys(value: Record<string, unknown>, expected: string[]): boolean {
  return Object.keys(value).sort().join() === expected.sort().join();
}
function fraction(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1;
}
function question(value: unknown, choices: string[]): boolean {
  if (!object(value) || !keys(value, ["type", "instructions", "criteria"])) return false;
  if (
    value.type !== "choice" ||
    typeof value.instructions !== "string" ||
    !value.instructions.trim()
  )
    return false;
  return (
    object(value.criteria) &&
    keys(value.criteria, choices) &&
    Object.values(value.criteria).every(
      (text) => typeof text === "string" && text.trim().length > 0,
    )
  );
}

export function parseProfile(setting: unknown): JudgeProfile | undefined {
  if (setting === undefined || setting === "") return undefined;
  const error = () =>
    new Error(
      "Invalid compact-adviser profile; advice is disabled. Restore valid version-1 profile JSON or clear the profile setting.",
    );
  if (typeof setting !== "string" || new TextEncoder().encode(setting).byteLength > 4096)
    throw error();
  let value: unknown;
  try {
    value = JSON.parse(setting);
  } catch {
    throw error();
  }
  if (
    !object(value) ||
    !keys(
      value,
      value.questions === undefined
        ? ["version", "coordinationWeight", "floors"]
        : ["version", "coordinationWeight", "floors", "questions"],
    )
  )
    throw error();
  if (
    value.version !== 1 ||
    !fraction(value.coordinationWeight) ||
    !Array.isArray(value.floors) ||
    value.floors.length < 1 ||
    value.floors.length > 8
  )
    throw error();
  let previousUsage = -1;
  let previousFloor = 1;
  for (const point of value.floors) {
    if (
      !Array.isArray(point) ||
      point.length !== 2 ||
      typeof point[0] !== "number" ||
      !Number.isFinite(point[0]) ||
      point[0] < 0 ||
      point[0] <= previousUsage ||
      !fraction(point[1]) ||
      point[1] > previousFloor
    )
      throw error();
    previousUsage = point[0];
    previousFloor = point[1];
  }
  if (
    value.questions !== undefined &&
    (!object(value.questions) ||
      !keys(value.questions, ["done", "shape"]) ||
      !question(value.questions.done, ["finished", "not_finished", "unclear"]) ||
      !question(value.questions.shape, ["hands_on", "coordinating", "unclear"]))
  )
    throw error();
  return value as unknown as JudgeProfile;
}
