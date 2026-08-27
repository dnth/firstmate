// Ordering for /supervision-model's model picker. docs/configuration.md owns
// its operator-facing behavior.
//
// This file holds only the choices Firstmate owns - which entries exist and in
// which order - so they stay testable without a terminal. The OMP port renders
// the rows through OMP's portable ctx.ui.select dialog (pickFromItems in
// fm-branch-supervision-omp.ts), so no fuzzy-filter or scroll-bound surface is
// needed here.

/** One row of the supervision-branch picker. */
export interface BranchPickerItem {
  /** Stable identity of the choice, used to resolve the captain's pick. */
  value: string;
  /** What the row shows. */
  label: string;
  /** Optional trailing note, such as marking the current choice. */
  description?: string;
}

/** The stable identity of the "follow main" row, which is always first. */
export const FOLLOW_MAIN_VALUE = "\0follow-main";

/**
 * Builds the picker's rows: "follow main" first, then the eligible models in
 * the order the caller resolved them. The current choice is marked so the
 * captain can see what is pinned without leaving the dialog.
 */
export function buildBranchModelItems(
  followMainLabel: string,
  modelLabels: readonly string[],
  currentPin: string | null,
): BranchPickerItem[] {
  const followMain: BranchPickerItem = {
    value: FOLLOW_MAIN_VALUE,
    label: followMainLabel,
    ...(currentPin === null ? { description: "current" } : {}),
  };
  return [
    followMain,
    ...modelLabels.map((label) => ({
      value: label,
      label,
      ...(currentPin !== null && label === currentPin ? { description: "current" } : {}),
    })),
  ];
}
