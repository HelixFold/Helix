/**
 * Every top-level field of helix.jsonc, both the compiler's and hpm's.
 *
 * @remarks
 * {@link loadManifest} reports any other field as a typo.
 *
 * @example
 * ```hx
 * ManifestFields.len; // 25
 * ```
 *
 * @since 1.0.0
 */

export const ManifestFields: readonly string[] = [
    "$schema", "name", "version", "description", "license", "author", "repository", "homepage", "keywords", "helix",
    "private", "exports", "c", "module", "bin", "scripts", "files", "dependencies", "devDependencies",
    "peerDependencies", "peerDependenciesMeta", "registries", "workspaces", "aliases", "chip",
];
