import ProjectDescription

let project = Project(
    name: "KanadeApp",
    organizationName: "petitstrawberry",
    targets: [
        .target(
            name: "KanadeApp",
            destinations: .iOS,
            product: .app,
            bundleId: "dev.ichigo.Kanade",
            deploymentTargets: .iOS("26.1"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "Kanade",
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                    "UIBackgroundModes": [
                        "audio",
                    ],
                    "NSAppTransportSecurity": [
                        "NSAllowsLocalNetworking": true,
                    ],
                    "NSBonjourServices": [
                        "_kanade._tcp",
                    ],
                    "NSLocalNetworkUsageDescription": "Kanade uses the local network to discover and connect to music servers.",
                ]
            ),
            sources: ["KanadeApp/Sources/**"],
            resources: ["KanadeApp/Resources/**"],
            scripts: [
                .post(
                    script: """
                    cp "${SRCROOT}/.package.resolved" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Package.resolved"
                    """,
                    name: "Copy Package.resolved",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .external(name: "KanadeKit"),
                .external(name: "AcknowList"),
            ],
            settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundle_DISPLAY_NAME": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "MARKETING_VERSION": "1.0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                ]
            ),
            additionalFiles: [".package.resolved"]
        ),
        .target(
            name: "KanadeAppMac",
            destinations: .macOS,
            product: .app,
            bundleId: "dev.ichigo.Kanade",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "Kanade",
                    "LSApplicationCategoryType": "public.app-category.music",
                    "NSAppTransportSecurity": [
                        "NSAllowsLocalNetworking": true,
                    ],
                    "NSBonjourServices": [
                        "_kanade._tcp",
                    ],
                    "NSLocalNetworkUsageDescription": "Kanade uses the local network to discover and connect to music servers.",
                    "NSSupportsAutomaticTermination": true,
                    "NSSupportsSuddenTermination": true,
                ]
            ),
            sources: ["KanadeApp/Sources/**"],
            resources: ["KanadeApp/Resources/**"],
            scripts: [
                .post(
                    script: """
                    cp "${SRCROOT}/.package.resolved" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/Package.resolved"
                    """,
                    name: "Copy Package.resolved",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .external(name: "KanadeKit"),
                .external(name: "AcknowList"),
            ],
              settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundle_DISPLAY_NAME": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "MARKETING_VERSION": "1.0.1",
                    "CURRENT_PROJECT_VERSION": "1",
                ],
                debug: [
                    "ENABLE_APP_SANDBOX": "NO",
                ],
                release: [
                    "ENABLE_APP_SANDBOX": "YES",
                    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
                ]
            ),
            additionalFiles: [".package.resolved"]
        ),
        .target(
            name: "KanadeAppTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "dev.ichigo.KanadeTests",
            infoPlist: .default,
            sources: ["KanadeApp/Tests/**"],
            dependencies: [
                .target(name: "KanadeApp"),
            ]
        ),
    ]
)
