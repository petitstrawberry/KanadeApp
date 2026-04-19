import ProjectDescription

let project = Project(
    name: "KanadeApp",
    organizationName: "petitstrawberry",
    packages: [
        .package(path: "KanadeKit"),
        .package(url: "https://github.com/sbooth/SFBAudioEngine", from: "0.12.1"),
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
            dependencies: [
                .package(product: "KanadeKit"),
                .package(product: "SFBAudioEngine"),
            ],
            settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundle_DISPLAY_NAME": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                    "SWIFT_OBJC_BRIDGING_HEADER": "KanadeApp/Sources/KanadeApp-Bridging-Header.h",
                ]
            )
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
            dependencies: [
                .package(product: "KanadeKit"),
                .package(product: "SFBAudioEngine"),
            ],
            settings: .settings(
                base: [
                    "INFOPLIST_KEY_CFBundleDisplayName": "Kanade",
                    "PRODUCT_DISPLAY_NAME": "Kanade",
                    "SWIFT_OBJC_BRIDGING_HEADER": "KanadeApp/Sources/KanadeApp-Bridging-Header.h",
                ]
            )
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
