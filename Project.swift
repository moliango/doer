import ProjectDescription

let developmentTeam = Environment.developmentTeam.getString(default: "")

let project = Project(
    name: "Doer",
    options: .options(
        defaultKnownRegions: ["en", "zh-Hans", "zh-Hant", "zh-HK"],
        developmentRegion: "en"
    ),
    packages: [
        .local(path: "Packages/CookedHTML"),
        .local(path: "Packages/DohProxy"),
        .remote(
            url: "https://github.com/scinfu/SwiftSoup.git",
            requirement: .upToNextMajor(from: "2.7.0")
        ),
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": .string(developmentTeam),
        ],
        configurations: [
            .debug(name: "Debug", settings: [:], xcconfig: nil),
            .release(name: "Release", settings: [:], xcconfig: nil),
        ]
    ),
    targets: [
        .target(
            name: "Doer",
            destinations: .iOS,
            product: .app,
            bundleId: "com.naine.doer",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .file(path: "Doer/Info.plist"),
            sources: [
                .glob("Doer/**", excluding: [
                    "Doer/Info.plist",
                    "Doer/Assets.xcassets/**",
                    "Doer/AppIcon.icon/**",
                    "Doer/AppIcons/**",
                ]),
                "Shared/TrustLevelWidgetSnapshot.swift",
            ],
            resources: .resources([
                .glob(pattern: "Doer/Assets.xcassets/**"),
                .glob(pattern: "Doer/AppIcons/**"),
                .glob(pattern: "Doer/Localizable.xcstrings"),
                .glob(pattern: "Doer/Core/aliases.json"),
                .glob(pattern: "Doer/Resources/Fonts/**"),
            ]),
            entitlements: .file(path: "Doer/Doer.entitlements"),
            dependencies: [
                .external(name: "Alamofire"),
                .external(name: "GRDB"),
                .external(name: "SDWebImage"),
                .external(name: "SDWebImageSVGCoder"),
                .external(name: "Lightbox"),
                .package(product: "CookedHTML"),
                .package(product: "DohProxy"),
                .package(product: "SwiftSoup"),
                .target(name: "DoerShare"),
                .target(name: "DoerWidget"),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "CODE_SIGN_STYLE": "Automatic",
                    "CURRENT_PROJECT_VERSION": "1",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "INFOPLIST_KEY_CFBundleDisplayName": "Doer",
                    "INFOPLIST_KEY_NSCameraUsageDescription": "用于在站内聊天中拍照并发送图片",
                    "INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription": "用于保存话题分享图片到相册",
                    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
                    "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
                    "INFOPLIST_KEY_CADisableMinimumFrameDurationOnPhone": "YES",
                    "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
                    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
                    "OTHER_LDFLAGS": "$(inherited) -ObjC",
                    "MARKETING_VERSION": "1.8.2",
                    "PRODUCT_NAME": "Doer",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_EMIT_LOC_STRINGS": "YES",
                    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
                    "SWIFT_VERSION": "5.0",
                    "TARGETED_DEVICE_FAMILY": "1,2",
                ]
            )
        ),
        .target(
            name: "DoerTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.naine.doerTests",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .default,
            sources: ["DoerTests/**"],
            dependencies: [
                .target(name: "Doer"),
            ]
        ),
        .target(
            name: "DoerShare",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.naine.doer.share",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .file(path: "Extensions/DoerShare/Info.plist"),
            sources: ["Extensions/DoerShare/**"],
            dependencies: [],
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "DEVELOPMENT_TEAM": .string(developmentTeam),
                    "PRODUCT_NAME": "DoerShare",
                    "SKIP_INSTALL": "YES",
                    "SWIFT_VERSION": "5.0",
                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                ]
            )
        ),
        .target(
            name: "DoerWidget",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.naine.doer.widget",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .file(path: "Extensions/DoerWidget/Info.plist"),
            sources: [
                "Extensions/DoerWidget/**",
                "Shared/TrustLevelWidgetSnapshot.swift",
            ],
            entitlements: .file(path: "Extensions/DoerWidget/DoerWidget.entitlements"),
            dependencies: [],
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "DEVELOPMENT_TEAM": .string(developmentTeam),
                    "PRODUCT_NAME": "DoerWidget",
                    "SKIP_INSTALL": "YES",
                    "SWIFT_VERSION": "5.0",
                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                ]
            )
        ),
    ],
    schemes: [
        .scheme(
            name: "DoerTests",
            shared: true,
            buildAction: .buildAction(targets: ["Doer", "DoerTests"]),
            testAction: .targets(["DoerTests"])
        ),
    ]
)
