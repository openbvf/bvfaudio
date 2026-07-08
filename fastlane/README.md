fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios check

```sh
[bundle exec] fastlane ios check
```

Validate App Store metadata against Apple content rules

### ios build

```sh
[bundle exec] fastlane ios build
```

Build for App Store distribution

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload a new build to TestFlight

### ios push_metadata

```sh
[bundle exec] fastlane ios push_metadata
```

Push App Store metadata text without submitting

### ios submit

```sh
[bundle exec] fastlane ios submit
```

Submit the latest TestFlight build to App Store review

----


## Mac

### mac check

```sh
[bundle exec] fastlane mac check
```

Validate App Store metadata against Apple content rules

### mac build

```sh
[bundle exec] fastlane mac build
```

Build for App Store distribution

### mac beta

```sh
[bundle exec] fastlane mac beta
```

Build and upload a new build to TestFlight

### mac push_metadata

```sh
[bundle exec] fastlane mac push_metadata
```

Push App Store metadata text without submitting

### mac submit

```sh
[bundle exec] fastlane mac submit
```

Submit the latest TestFlight build to App Store review

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
