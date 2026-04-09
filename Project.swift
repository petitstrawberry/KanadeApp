import ProjectDescription

let project = Project(
    name: "KanadeApp",
    organizationName: "petitstrawberry",
    packages: [
        .package(path: "KanadeKit"),
    ],
    targets: [
        Target(
            name: "KanadeApp",
            platform: .iOS,
            product: .app,
            bundleId: "com.petitstrawberry.KanadeApp",
            deploymentTarget: DeploymentTarget.iOS(targetVersion: "26.0", devices: [.iphone, .ipad]),
            infoPlist: .extendingDefault(
                with: [
                    "UILaunchScreen": [
                        "UIColorName": "",
                        "UIImageName": "",
                    ],
                    "NSAppTransportSecurity": [
                        "NSAllowsLocalNetworking": true,
                    ],
                ]
            ),
            sources: ["KanadeApp/Sources/**"],
            resources: ["KanadeApp/Resources/**"],
            dependencies: [
                .package(product: "KanadeKit"),
            ]
        ),
        Target(
            name: "KanadeAppMac",
            platform: .macOS,
            product: .app,
            bundleId: "com.petitstrawberry.KanadeAppMac",
            deploymentTarget: DeploymentTarget.macOS(targetVersion: "26.0"),
            infoPlist: .extendingDefault(
                with: [
                    "NSAppTransportSecurity": [
                        "NSAllowsLocalNetworking": true,
                    ],
                ]
            ),
            sources: ["KanadeApp/Sources/**"],
            resources: ["KanadeApp/Resources/**"],
            entitlements: "KanadeApp/Config/KanadeAppMac.entitlements",
            dependencies: [
                .package(product: "KanadeKit"),
            ]
        ),
        Target(
            name: "KanadeAppTests",
            platform: .iOS,
            product: .unitTests,
            bundleId: "com.petitstrawberry.KanadeAppTests",
            infoPlist: .default,
            sources: ["KanadeApp/Tests/**"],
            dependencies: [
                .target(name: "KanadeApp"),
            ]
        ),
    ]
)
