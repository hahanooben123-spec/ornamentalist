# iPad-only feasibility — evaluated 17 October 2026

Phase 1 can be developed and run entirely in an iPad app playground. Apple explicitly supports writing SwiftUI apps and submitting app playgrounds from iPad in [Swift Playgrounds documentation](https://developer.apple.com/documentation/swift-playgrounds). Its [iPad file guide](https://support.apple.com/en-lamr/guide/playgrounds-ipad/itc18b7bce9d/4.6/ipados/18.0) documents multiple Swift files and Swift packages. This implementation needs only built-in Apple frameworks.

| Requirement | iPad-only route | Remaining verification or limitation |
| --- | --- | --- |
| Native app and interface | SwiftUI app playground, UIKit view via UIViewRepresentable | Must compile with the SDK shipped in the installed Swift Playground |
| Real Pencil samples | UIView touch overrides, coalesced and predicted UIKit touches | Pressure, palm interactions, cancellations, and latency need an actual Pencil |
| Symmetric live drawing | MTKView with instanced Metal geometry | 8–64 copies need device frame-time measurements |
| Shader compilation | Compile short embedded Metal source using MTLDevice at runtime | Avoids `.metal` build phases; first renderer creation can incur shader compilation cost |
| Local documents and PNG | Foundation actor, Codable, Core Graphics, native share sheet | App sandbox storage; no iCloud entitlement or Photos permission required |
| Automated tests | Included Swift/XCTest sources executed on cloud macOS | The delivered workflow, not an iPad terminal, supplies repeatable test execution |
| Instruments and deeper GPU analysis | Later cloud Mac/Xcode investigation; manual device testing now | Simulator timings do not establish Apple Pencil latency; Instruments/device GPU capture requires appropriate Apple tools and access to the device |
| Standalone distribution | Swift Playground's supported submission path, or signed cloud Xcode archive | Requires your Apple developer identity and distribution configuration |

Apple provides [coalesced input](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches) and [predicted touches](https://developer.apple.com/documentation/uikit/uievent/predictedtouches(for:)) for high-fidelity ink. Predictions must be replaced with real samples, not committed into the drawing. The prototype follows that separation. Apple also documents [runtime Metal library compilation](https://developer.apple.com/documentation/metal/mtldevice/makelibrary(source:options:)).

PencilKit is a strong default for conventional ink tools. Here, app-owned incoming samples and explicit instancing make the real-time symmetry requirement straightforward without depending on completion-time PKDrawing mirroring. A minimal custom renderer is justified by that requirement; it does not reproduce PencilKit's mature brush system or all its input refinements.

## Simplest viable architecture

SwiftUI owns gallery/settings state. A UIKit/MTKView owns touch delivery and gestures. It immediately converts samples through the inverse viewport matrix into document coordinates. The geometry builder smooths only the original stroke. Metal applies the same radial affine matrices to that geometry in one instanced draw per vertex chunk. One actor saves Codable documents; another produces PNG exports using the same geometry and matrices through Core Graphics.

This uses no third-party library, React Native runtime, shader compiler plugin, custom Xcode phase, or Mac-generated binary. The iPad manifest uses AppleProductTypes, which is app-playground tooling rather than a generic cross-platform SwiftPM API. The root package tests the portable code separately; it is not an alternate iPad executable.

## Cloud Mac plan

1. Keep the complete source in a GitHub repository. The browser on iPad can upload/edit files and start the provided workflow.
2. Use the included GitHub-hosted macOS job for Swift tests and simulator compilation. GitHub documents its [hosted runner execution model](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners). Runner usage and availability follow the repository owner's GitHub plan. See [verified build results](BUILD_STATUS.md) for the actual cloud test record.
3. Inspect the `.xcresult` artifact and fix any compiler/runtime failures before treating the source as validated. The XcodeGen description is only used on that runner.
4. Run the exact source in Swift Playground on your physical iPad and complete the checklist. Automated simulator tests cannot substitute for Pencil testing.
5. When standalone distribution is needed, add an archive/export job using your signing certificate/provisioning profile and App Store Connect credentials stored as CI secrets. Change the prototype bundle ID to your registered ID, enable signing for that job, then distribute via TestFlight. The supplied workflow intentionally builds only the simulator and contains no distribution credentials.

The feasibility conclusion is based on framework capabilities, not a claim that this particular generated app has already passed compilation or acceptance testing.
