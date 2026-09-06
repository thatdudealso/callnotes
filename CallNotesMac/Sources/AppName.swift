//
//  AppName.swift
//  CallNotesMac
//
//  Vendored from Megaphone (https://github.com/Kuberwastaken/megaphone),
//  MIT License:
//    Copyright (c) 2026 Kuber Mehta (Megaphone)
//    Copyright (c) 2026 Zach Latta (FreeFlow)
//  See THIRD_PARTY.md. Adapted for CallNotes branding.
//

import Foundation

enum AppName {
    static let displayName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CallNotes"
}
