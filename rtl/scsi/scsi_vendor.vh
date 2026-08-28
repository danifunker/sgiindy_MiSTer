// SCSI INQUIRY vendor id for rtl/scsi.v — MUST be exactly 8 bytes, space-padded.
//
// Committed value is "MiSTer  ". For a throwaway / co-test build (e.g. BlueSCSI
// Toolbox bring-up) change the string below locally, and keep your edit out of
// commits so no build-specific vendor ever lands in the tracked source:
//   git update-index --skip-worktree rtl/scsi_vendor.vh     # ignore local edits
//   git update-index --no-skip-worktree rtl/scsi_vendor.vh  # resume tracking
`define SCSI_VENDOR_STRING "MiSTer  "
