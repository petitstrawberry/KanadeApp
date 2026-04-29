import ProjectDescription

let project = Project(
    name: "KanadeApp",
    organizationName: "petitstrawberry",
    packages: [
        .package(url: "https://github.com/petitstrawberry/KanadeKit.git", from: "0.2.0"),
        .package(url: "https://github.com/vtourraine/AcknowList.git", from: "3.0.0"),
    ],
    targets: [
        Target(
            name: "KanadeApp",
            platform: .iOS,
            product: .app,
            bundleId: "dev.ichigo.KanadeApp",
            deploymentTarget: DeploymentTarget.iOS(targetVersion: "26.0", devices: [.iphone, .ipad]),
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
                .package(product: "KanadeKit"),
                .package(product: "AcknowList"),
            ],
            settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundle_DISPLAY_NAME": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                ]
            ),
            additionalFiles: [".package.resolved"],
        ),
        Target(
            name: "KanadeAppMac",
            platform: .macOS,
            product: .app,
            bundleId: "dev.ichigo.KanadeAppMac",
            deploymentTarget: DeploymentTarget.macOS(targetVersion: "26.0"),
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
                ]
            ),
            sources: ["KanadeApp/Sources/**"],
            resources: ["KanadeApp/Resources/**"],
            entitlements: "KanadeApp/Config/KanadeAppMac.entitlements",
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
                .package(product: "KanadeKit"),
                .package(product: "AcknowList"),
            ],
            settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundle_DISPLAY_NAME": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                ]
            ),
            additionalFiles: [".package.resolved"],
        ),
        Target(
            name: "KanadeAppTests",
            platform: .iOS,
            product: .unitTests,
            bundleId: "dev.ichigo.KanadeAppTests",
            infoPlist: .default,
            sources: ["KanadeApp/Tests/**"],
            dependencies: [
                .target(name: "KanadeApp"),
            ]
        ),
    ]
)
