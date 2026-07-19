#!/usr/bin/env node
/**
 * Hide "Show pet" / "Hide pet" and "Invite a friend" / "Invite a coworker"
 * from the Codex profile dropdown by nulling their React menu rows in the
 * extracted ASAR webview bundles.
 *
 * Usage:
 *   node patch-hide-profile-menu.js <extracted-asar-dir>
 */

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const MARKER = "__chatgptPatcherHideProfileMenuInstalled";
const SHOW_PET_ID = "codex.profileFooter.showPet";
const INVITE_FRIEND_ID = "codex.profileDropdown.inviteFriend";

/** Newer bundles: pet label is inlined, then wrapped as electron:!0 children:IDENT */
const PET_WRAPPER_PATTERN =
    /([A-Za-z_$][\w$]*)=\(0,([A-Za-z_$][\w$]*)\.jsx\)\(([A-Za-z_$][\w$]*),\{electron:!0,children:([A-Za-z_$][\w$]*)\}\)/;

/** Older bundles: electron wrapper nests the Qo/G row with LeftIcon/onClick/children */
const PET_NESTED_PATTERN =
    /([A-Za-z_$][\w$]*)=\(0,([A-Za-z_$][\w$]*)\.jsx\)\(([A-Za-z_$][\w$]*),\{electron:!0,children:\(0,\2\.jsx\)\(([A-Za-z_$][\w$]*),\{LeftIcon:[A-Za-z_$][\w$]*,onClick:[A-Za-z_$][\w$]*,children:([A-Za-z_$][\w$]*)\}\)\}\)/;

const INVITE_PATTERN =
    /([A-Za-z_$][\w$]*)=\(0,([A-Za-z_$][\w$]*)\.jsx\)\(([A-Za-z_$][\w$]*),\{LeftIcon:[A-Za-z_$][\w$]*,leftIconClassName:`icon-xs`,onClick:[A-Za-z_$][\w$]*,children:([A-Za-z_$][\w$]*)\}\)/;

function findJsFiles(dir) {
    let results = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const fullPath = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            results = results.concat(findJsFiles(fullPath));
        } else if (entry.name.endsWith(".js")) {
            results.push(fullPath);
        }
    }
    return results;
}

function looksLikeProfileMenuBundle(content) {
    // Locale catalogs also mention the message IDs. Require the electron pet
    // row and invite row shapes so we only patch the rendered dropdown.
    return (
        content.includes(SHOW_PET_ID) &&
        content.includes(INVITE_FRIEND_ID) &&
        content.includes("electron:!0") &&
        content.includes("leftIconClassName:`icon-xs`")
    );
}

function findProfileMenuBundle(assetsDir) {
    const jsFiles = findJsFiles(assetsDir);
    for (const file of jsFiles) {
        const content = fs.readFileSync(file, "utf8");
        if (looksLikeProfileMenuBundle(content)) {
            return { file, content };
        }
    }
    return null;
}

function replaceFirstInWindow(content, anchorIndex, before, after, patterns) {
    const windowStart = Math.max(0, anchorIndex - before);
    const windowEnd = Math.min(content.length, anchorIndex + after);
    const slice = content.slice(windowStart, windowEnd);

    for (const pattern of patterns) {
        pattern.lastIndex = 0;
        const match = slice.match(pattern);
        if (!match) continue;
        const absoluteIndex = windowStart + match.index;
        const replacement = `${match[1]}=null`;
        return {
            content:
                content.slice(0, absoluteIndex) +
                replacement +
                content.slice(absoluteIndex + match[0].length),
            matched: match[0],
            replacement,
        };
    }
    return null;
}

/**
 * Null the electron-only pet menu row that follows the showPet/hidePet labels.
 * Supports both the current inlined-label shape and the older nested Qo shape.
 */
function hidePetMenuItem(content) {
    const anchor = content.indexOf(SHOW_PET_ID);
    if (anchor < 0) {
        throw new Error(`Could not find ${SHOW_PET_ID} in the profile menu bundle.`);
    }

    const result = replaceFirstInWindow(content, anchor, 200, 1600, [
        PET_WRAPPER_PATTERN,
        PET_NESTED_PATTERN,
    ]);
    if (!result) {
        throw new Error(
            "Could not find the Show pet / Hide pet profile menu row. " +
                "The app may have been updated with a restructured profile dropdown."
        );
    }
    return result.content;
}

/**
 * Null the invite menu row that follows the inviteFriend / inviteCoworker labels.
 */
function hideInviteMenuItem(content) {
    const anchor = content.indexOf(INVITE_FRIEND_ID);
    if (anchor < 0) {
        throw new Error(`Could not find ${INVITE_FRIEND_ID} in the profile menu bundle.`);
    }

    const result = replaceFirstInWindow(content, anchor, 100, 1000, [INVITE_PATTERN]);
    if (!result) {
        throw new Error(
            "Could not find the Invite a friend profile menu row. " +
                "The app may have been updated with a restructured profile dropdown."
        );
    }
    return result.content;
}

function ensureMarker(content) {
    if (content.includes(MARKER)) {
        return content;
    }
    return `${content}\n;globalThis.${MARKER}=true;\n`;
}

function syntaxCheck(filePath) {
    const result = spawnSync(process.execPath, ["--check", filePath], {
        encoding: "utf8",
    });
    if (result.status !== 0) {
        const detail = (result.stderr || result.stdout || "Unknown parse error").trim();
        throw new Error(`JavaScript syntax check failed for ${path.basename(filePath)}:\n${detail}`);
    }
}

function main() {
    const extractedDir = process.argv[2];
    if (!extractedDir) {
        console.error("Usage: node patch-hide-profile-menu.js <extracted-asar-dir>");
        process.exit(1);
    }

    const assetsDir = path.join(extractedDir, "webview", "assets");
    if (!fs.existsSync(assetsDir)) {
        console.error("ERROR: webview/assets directory not found in extracted asar.");
        process.exit(1);
    }

    const target = findProfileMenuBundle(assetsDir);
    if (!target) {
        console.error(
            "ERROR: Could not find a bundle containing both profile pet and invite menu items."
        );
        console.error("The app may have been updated with a restructured profile dropdown.");
        process.exit(1);
    }

    console.log("  Found profile menu bundle: " + path.basename(target.file));

    let content = target.content;
    if (content.includes(MARKER)) {
        console.log("  Hide-profile-menu patch already present; refreshing transforms.");
    }

    content = hidePetMenuItem(content);
    console.log("  Removed Show pet / Hide pet from the profile dropdown.");

    content = hideInviteMenuItem(content);
    console.log("  Removed Invite a friend / coworker from the profile dropdown.");

    content = ensureMarker(content);
    fs.writeFileSync(target.file, content);
    syntaxCheck(target.file);

    console.log("  JavaScript syntax check passed.");
    console.log("HIDE_PROFILE_MENU_FILE=" + target.file);
}

if (require.main === module) {
    try {
        main();
    } catch (error) {
        console.error("ERROR: " + (error && error.message ? error.message : error));
        process.exit(1);
    }
}

module.exports = {
    MARKER,
    SHOW_PET_ID,
    INVITE_FRIEND_ID,
    findProfileMenuBundle,
    hidePetMenuItem,
    hideInviteMenuItem,
};
