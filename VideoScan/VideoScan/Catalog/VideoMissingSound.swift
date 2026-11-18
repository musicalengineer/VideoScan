// VideoMissingSound.swift
// Show ▸ Videos Missing Sound (DECISIONS 2026-11-17, "Show menu, final shape
// for now"): the videos whose sound is missing — the ones that need their
// sound found, combined or repaired before they can be archived.
//
// ONE ENGINE. The verdict on a file's sound is `ArchiveReadiness.SoundStanding`
// — the reading of the stored sound check that the Promote sheet and the
// Archive Angel show, in the Promote gate's own terms. This file only says
// WHICH standings count as "missing"; it reads no verify field itself.
//
// THE RULE. A file with a confirmed picture (video+audio or video-only; an
// un-probeable file is not known to be a video) whose standing is:
//   .noTrack     no audio stream ............ LISTED, unless the file is the
//                                             picture half of a pair
//                                             (`pairedWith`): its sound exists,
//                                             in the paired audio file
//   .refusable   measured silent, a check that found no stream, or sound
//                stored as damaged .......... LISTED (a damaged pair half too)
//   .accepted    silent or no track, and the owner's “Silent — checked” tag
//                covers the file as catalogued  NOT listed: the owner has looked
//                and ruled that no sound is right for it; Promote accepts it;
//                the standing itself counts it as "noted", not "refused"
//   .unbalanced  left-only / right-only / lopsided  NOT listed (Prepare balances)
//   .note        mono ....................... NOT listed
//   .unmeasured  surround, several live tracks  NOT listed
//   .notChecked  never checked .............. NOT listed (nothing is known yet)
//   .fine        ............................ NOT listed
// So: exactly the standings Promote would refuse (`bucket == .refused`), minus
// the paired picture half.
//
// COST. O(1) per record from stored fields: a few string compares, one split
// of the short stored note, one scan of the record's tags. No decode, no disk.

import Foundation
import VideoScanCore

enum VideoMissingSound {

    /// Does this standing mean the sound is missing? `hasPairedSound`: the
    /// file is the picture half of a correlated pair. Pure; every case named
    /// so a new standing cannot be forgotten here.
    nonisolated static func counts(_ standing: ArchiveReadiness.SoundStanding, hasPairedSound: Bool) -> Bool {
        switch standing {
        case .noTrack: return !hasPairedSound
        case .refusable: return true
        case .accepted, .unbalanced, .note, .unmeasured, .notChecked, .fine: return false
        }
    }

    /// THE Show ▸ Videos Missing Sound test for one record.
    nonisolated static func matches(_ rec: VideoRecord) -> Bool {
        let stream = rec.streamType
        guard stream == .videoAndAudio || stream == .videoOnly else { return false }
        return counts(ArchiveReadiness.storedSoundStanding(of: rec), hasPairedSound: rec.pairedWith != nil)
    }
}
