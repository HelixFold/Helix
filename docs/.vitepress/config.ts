/**
 * Imports
 */

import { defineVersionedConfig } from '@viteplus/versions';

/**
 * Doc config
 */

export default defineVersionedConfig({
    title: 'Helix',
    base: '/Helix/',
    description: 'A systems language with TypeScript syntax, no hidden control flow, and explicit allocators',
    head: [
        [ 'link', { rel: 'icon', type: 'image/svg+xml', href: '/Helix/logo.svg' }],
        [ 'meta', { name: 'theme-color', content: '#bd34fe' }]
    ],
    markdown: {
        // Helix reads like TypeScript, so its code blocks borrow the TypeScript grammar
        languageAlias: { hx: 'ts' },
        languageLabel: { hx: 'helix' }
    },
    versionsConfig: {
        current: 'v1.0.x',
        // Switch to { text: 'Version', includeCurrentVersion: true } after archiving a version.
        versionSwitcher: false
    },
    themeConfig: {
        logo: '/logo.svg',

        search: {
            provider: 'local'
        },

        nav: [
            { text: 'Home', link: '/' },
            { text: 'Guide', link: '/guide' },
            {
                text: 'Language',
                items: [
                    { text: 'Basics', link: '/language/basics' },
                    { text: 'Functions', link: '/language/functions' },
                    { text: 'Structs, Enums, and Unions', link: '/language/types' },
                    { text: 'Control Flow', link: '/language/control-flow' },
                    { text: 'Errors', link: '/language/errors' },
                    { text: 'Optionals', link: '/language/optionals' },
                    { text: 'Memory', link: '/language/memory' },
                    { text: 'Generics and Interfaces', link: '/language/generics' },
                    { text: 'Compile Time', link: '/language/comptime' },
                    { text: 'Modules', link: '/language/modules' },
                    { text: 'C Interop', link: '/language/c-interop' },
                    { text: 'Safety', link: '/language/safety' }
                ]
            },
            {
                text: 'Projects',
                items: [
                    { text: 'helix.jsonc', link: '/projects/manifest' },
                    { text: 'build.hx', link: '/projects/build' },
                    { text: 'Testing', link: '/projects/testing' },
                    { text: 'Targets', link: '/projects/targets' }
                ]
            },
            {
                text: 'Reference',
                items: [
                    { text: 'Command Line', link: '/reference/cli' },
                    { text: 'Standard Library', link: '/reference/std' }
                ]
            },
            { component: 'VersionSwitcher' }
        ],

        // Object keyed by version: `root` = current (docs/src), `vX.x.x` = archived.
        sidebar: {
            root: [
                { text: 'Getting Started', link: '/guide' },
                { text: 'Release Notes', link: '/release' },
                {
                    text: 'Language',
                    items: [
                        { text: 'Basics', link: '/language/basics' },
                        { text: 'Functions', link: '/language/functions' },
                        { text: 'Structs, Enums, and Unions', link: '/language/types' },
                        { text: 'Control Flow', link: '/language/control-flow' },
                        { text: 'Errors', link: '/language/errors' },
                        { text: 'Optionals', link: '/language/optionals' },
                        { text: 'Memory', link: '/language/memory' },
                        { text: 'Generics and Interfaces', link: '/language/generics' },
                        { text: 'Compile Time', link: '/language/comptime' },
                        { text: 'Modules', link: '/language/modules' },
                        { text: 'C Interop', link: '/language/c-interop' },
                        { text: 'Safety', link: '/language/safety' }
                    ]
                },
                {
                    text: 'Projects',
                    items: [
                        { text: 'helix.jsonc', link: '/projects/manifest' },
                        { text: 'build.hx', link: '/projects/build' },
                        { text: 'Testing', link: '/projects/testing' },
                        { text: 'Targets', link: '/projects/targets' }
                    ]
                },
                {
                    text: 'Reference',
                    items: [
                        { text: 'Command Line', link: '/reference/cli' },
                        { text: 'Standard Library', link: '/reference/std' }
                    ]
                }
            ]
        },

        socialLinks: [
            { icon: 'github', link: 'https://github.com/HelixFold/Helix' }
        ],

        docFooter: {
            prev: true,
            next: true
        },

        footer: {
            message: 'Released under the MIT License',
            copyright: `Copyright © ${ new Date().getFullYear() } HelixFold Contributors`
        }
    }
});
