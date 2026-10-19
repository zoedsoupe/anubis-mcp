# Changelog

All notable changes to this project will be documented in this file.

## [0.11.3](https://github.com/zoedsoupe/peri/compare/v0.11.2...v0.11.3) (2026-10-01)

### Bug Fixes

* generate floats for {:float, {:range, {min, max}}} ([9650166](https://github.com/zoedsoupe/peri/commit/965016674ce9532a5cc12e65416077074422732e)), closes [#81](https://github.com/zoedsoupe/peri/issues/81)
* keep unique list generation within length bounds ([1e0d4e9](https://github.com/zoedsoupe/peri/commit/1e0d4e99894c852f350e2e6ac62894c2caa161e5)), closes [#80](https://github.com/zoedsoupe/peri/issues/80)
* skip non-string keys in spellcheck candidates ([1b1e443](https://github.com/zoedsoupe/peri/commit/1b1e443e0d7bfc6ada0ecdc22ba32294a477283e)), closes [#82](https://github.com/zoedsoupe/peri/issues/82)

## [0.11.2](https://github.com/zoedsoupe/peri/compare/v0.11.1...v0.11.2) (2026-08-17)


### Bug Fixes

* clear errors for dependent callback contract breaches ([2423cd9](https://github.com/zoedsoupe/peri/commit/2423cd9b996d44607cfa99cff84d4b5a580a075b))

## [0.11.1](https://github.com/zoedsoupe/peri/compare/v0.11.0...v0.11.1) (2026-08-15)


### Bug Fixes

* build phoenix test schema at runtime for Elixir &lt; 1.19 ([c9d7693](https://github.com/zoedsoupe/peri/commit/c9d7693bc4e1ed3a56997966f73a7ac77dbd1ac2))

## [0.11.0](https://github.com/zoedsoupe/peri/compare/v0.10.0...v0.11.0) (2026-08-15)


### Features

* coerce shorthand, atom!/enum/literal targets, split lists ([2dbb994](https://github.com/zoedsoupe/peri/commit/2dbb994eb4a4ca7bef08238189477a125eb81f47))


### Documentation

* slim README, moduledoc reads it via File.read! ([068f987](https://github.com/zoedsoupe/peri/commit/068f98721aea8bdf4e974d80bb4e1f0ea465bc5e))

## [0.10.0](https://github.com/zoedsoupe/peri/compare/v0.9.1...v0.10.0) (2026-08-11)


### Features

* {:coerce, source, target} directive with decode/encode ([40ef5f4](https://github.com/zoedsoupe/peri/commit/40ef5f439d74584de1e7063e5f8c8cd83f16ff4a))
* error humanize, missing-key spellcheck, legible oneof summaries ([94f1a75](https://github.com/zoedsoupe/peri/commit/94f1a757fb6e1fef75747bc923ae613ee6594f37))
* Phoenix form bridge via Peri.Form and FormData protocol ([b791bb0](https://github.com/zoedsoupe/peri/commit/b791bb0e11171abd465329d2b38a961a075d5762))
* schema composition with merge/select/except ([898eeda](https://github.com/zoedsoupe/peri/commit/898eeda279b79970e57529ffb0cacf2770ece675))


### Bug Fixes

* form list_entries crash on non-numeric param keys ([a8de6a2](https://github.com/zoedsoupe/peri/commit/a8de6a2688ff3f3dbb718a6edbfaff3420438a18))
* humanize deep_merge crash on prefix-colliding error paths ([6b7f686](https://github.com/zoedsoupe/peri/commit/6b7f6867e4832c7edb590db59695c79b344c04bc))

## [0.9.1](https://github.com/zoedsoupe/peri/compare/v0.9.0...v0.9.1) (2026-08-07)


### Bug Fixes

* ambigous numeric validation, integers allowed floats and vice-versa ([993eabf](https://github.com/zoedsoupe/peri/commit/993eabf2c77fa06bf5865deb8c584a9ea622a89c)), closes [#72](https://github.com/zoedsoupe/peri/issues/72)

## [0.9.0](https://github.com/zoedsoupe/peri/compare/v0.8.5...v0.9.0) (2026-06-10)


### Features

* elixir 1.20.0 compiler fixes ([5b93739](https://github.com/zoedsoupe/peri/commit/5b93739fc6dbf9c80cdbac4105289dcb92b623d5))

## [0.8.5](https://github.com/zoedsoupe/peri/compare/v0.8.4...v0.8.5) (2026-05-23)


### Bug Fixes

* error_to_map nil content handling ([#69](https://github.com/zoedsoupe/peri/issues/69)) ([a140299](https://github.com/zoedsoupe/peri/commit/a140299ad355d5df07e2a85add96b11ea52c59b3))

## [0.8.4](https://github.com/zoedsoupe/peri/compare/v0.8.3...v0.8.4) (2026-05-04)


### Bug Fixes

* decode JSON Schema number/integer to either int|float per spec ([#68](https://github.com/zoedsoupe/peri/issues/68)) ([dc88c0f](https://github.com/zoedsoupe/peri/commit/dc88c0f17c9114444c72cce148dc2cbb88204274))
* predictable JSON Schema decoder keys via :keys opt ([#66](https://github.com/zoedsoupe/peri/issues/66)) ([ce9caeb](https://github.com/zoedsoupe/peri/commit/ce9caeba35ab706e00fc2b4cfdc8b383b5dc39a9))

## [0.8.3](https://github.com/zoedsoupe/peri/compare/v0.8.2...v0.8.3) (2026-04-29)


### Features

* typed enum and exclude_meta_keys JSON Schema opt ([#62](https://github.com/zoedsoupe/peri/issues/62)) ([82d3edd](https://github.com/zoedsoupe/peri/commit/82d3eddf58bd98d8e0271f3a418dc80599f2c315))

## [0.8.2](https://github.com/zoedsoupe/peri/compare/v0.8.1...v0.8.2) (2026-04-29)


### Features

* extend JSON Schema meta vocab to Draft-7 keywords ([#59](https://github.com/zoedsoupe/peri/issues/59)) ([0f832a2](https://github.com/zoedsoupe/peri/commit/0f832a21eb676b70e238eb0d916839c068636dee))

## [0.8.1](https://github.com/zoedsoupe/peri/compare/v0.8.0...v0.8.1) (2026-04-28)


### Miscellaneous Chores

* fix compilation warning ([d2eeaa7](https://github.com/zoedsoupe/peri/commit/d2eeaa7c48d91ea1153cc49b9d76bab289ca525f))

## [0.8.0](https://github.com/zoedsoupe/peri/compare/v0.7.0...v0.8.0) (2026-04-28)


### Features

* compact schema summaries in error messages ([#57](https://github.com/zoedsoupe/peri/issues/57)) ([e2b6c0b](https://github.com/zoedsoupe/peri/commit/e2b6c0b5842a6e4e3a4418d79d4010f7bea78aaf))
* list constraints (:min/:max/:unique) and :multiple_of ([#56](https://github.com/zoedsoupe/peri/issues/56)) ([859255d](https://github.com/zoedsoupe/peri/commit/859255d911c14af795a2d69f9a6d1bded7c30ea2))

## [0.7.0](https://github.com/zoedsoupe/peri/compare/v0.6.2...v0.7.0) (2026-04-27)


### Features

* add :meta wrapper and schema-level meta opts ([#47](https://github.com/zoedsoupe/peri/issues/47)) ([b63584c](https://github.com/zoedsoupe/peri/commit/b63584c6ef61c81521b991210129b175a616afd5))
* add :multi directive for tagged unions ([#51](https://github.com/zoedsoupe/peri/issues/51)) ([4727871](https://github.com/zoedsoupe/peri/commit/47278718d4079977742df9c69f9e7476c9c4be3d))
* add :ref directive for recursive and cross-module schemas ([#50](https://github.com/zoedsoupe/peri/issues/50)) ([b5c778b](https://github.com/zoedsoupe/peri/commit/b5c778bee3bd5d1cb317ff05d6281323bf8a575d))
* add JSON Schema (Draft 7) bidirectional conversion ([#49](https://github.com/zoedsoupe/peri/issues/49)) ([7a78a14](https://github.com/zoedsoupe/peri/commit/7a78a14eda19abe6952e0ec5e852d5002ac78fc5))
* add Peri.walk/2 schema rewriter ([#53](https://github.com/zoedsoupe/peri/issues/53)) ([1464f3f](https://github.com/zoedsoupe/peri/commit/1464f3f77f27a9471f80bd07532db96943dc444c))
* per-field custom error overrides + i18n hook ([#52](https://github.com/zoedsoupe/peri/issues/52)) ([838514c](https://github.com/zoedsoupe/peri/commit/838514cff8c9b074dbfca79cd269d20b48ddb7b7))
* per-field gen: override for StreamData generation ([#54](https://github.com/zoedsoupe/peri/issues/54)) ([029da56](https://github.com/zoedsoupe/peri/commit/029da561cb39f62ae6f9e9a8145e4bb09887706d))

## [0.6.2](https://github.com/zoedsoupe/peri/compare/v0.6.1...v0.6.2) (2025-08-27)

### Bug Fixes

- default appliance on nested partial required schema ([#45](https://github.com/zoedsoupe/peri/issues/45)) ([01a6ca2](https://github.com/zoedsoupe/peri/commit/01a6ca25370f9748fa6cccb271076122387c948e))

### Continuous Integration

- add auto hex publish ([3d7e67a](https://github.com/zoedsoupe/peri/commit/3d7e67a7986cd6cbaaf9df193c75e95564e02548))

## [0.6.1](https://github.com/zoedsoupe/peri/compare/v0.6.0...v0.6.1) (2025-08-14)

### Bug Fixes

- schema with nested required fields ([#41](https://github.com/zoedsoupe/peri/issues/41)) ([69e843a](https://github.com/zoedsoupe/peri/commit/69e843a528524e463bb2e9020eecc1fd39398362))

## [0.6.0](https://github.com/zoedsoupe/peri/compare/v0.5.1...v0.6.0) (2025-07-16)

### Features

- `:schema` validator that can accept additional keys ([#37](https://github.com/zoedsoupe/peri/issues/37)) ([098be96](https://github.com/zoedsoupe/peri/commit/098be96a106671119bc7ea83d6fe9099a2319c36))
- multiple validator options ([#35](https://github.com/zoedsoupe/peri/issues/35)) ([2c5ec2f](https://github.com/zoedsoupe/peri/commit/2c5ec2fccdb90663372f90fe6d21ec9ce9f48133))

## [0.5.1] - 2025-6-29

### Added

- Split out `validation_result` from validation type for reuse (#34)

## [0.5.0] - 2025-06-18

### Added

- **Validation Modes**: New permissive mode allows preserving fields not defined in the schema (#33)
  - Default mode remains `:strict` which filters out undefined fields
  - New `:permissive` mode preserves all input fields while still validating defined fields
  - Support for mode option in `defschema` macro: `defschema :name, schema, mode: :permissive`
  - Useful for API gateways, progressive validation, and middleware scenarios

### Fixed

- Fixed nested schemas in lists not having their keys atomized properly (#32)
  - String keys in nested schemas within lists are now correctly converted to atoms
  - Maintains consistent behavior with top-level schema validation

### Internal

- Added `CLAUDE.md` file for AI-assisted development guidance
- Enhanced `.formatter.exs` to export `defschema/3` for proper formatting

## [0.4.1] - 2025-06-18

### Changed

- **BREAKING**: Minimum Elixir version requirement is now 1.17 due to `Duration` struct usage introduced in 0.4.0
  - The `Duration` struct was introduced in Elixir 1.17
  - Previous `mix.exs` incorrectly specified `~> 1.16` compatibility

## [0.4.0] - 2025-10-06 [YANKED]

### Added

- **Ecto Integration**: New `Peri.to_changeset!/2` function to generate Ecto changesets from Peri schemas
  - Automatically generated `<name>_changeset/1` functions when defining schemas with `defschema` (when Ecto is loaded)
  - Support for all Peri types in Ecto changesets including nested schemas, custom types, and validations
  - Custom Ecto types: `Peri.Ecto.Type.PID`, `Peri.Ecto.Type.Atom`, `Peri.Ecto.Type.Any`, `Peri.Ecto.Type.Tuple`, `Peri.Ecto.Type.Either`, `Peri.Ecto.Type.OneOf`
  - Full support for embedded schemas with `:oneof`, `:either`, and nested map validations
  - Comprehensive validation rules are preserved when converting to changesets

- **New Types**:
  - `:duration` type for validating `%Duration{}` structs
- **JSON Support**:
  - Added `Jason.Encoder` protocol implementation for `Peri.Error`
  - Support for encoding errors as JSON when Jason is available
- **Performance Benchmarks**:
  - Added benchmark suite comparing Peri validation with Ecto changeset generation
  - Benchmarks for both simple and complex schemas

### Changed

- Updated Elixir version requirement in development environment to 1.19.0-rc.0
- Updated nix flake configuration with elixir-overlay
- Improved error handling and JSON encoding for `Peri.Error`

### Internal

- Major refactoring of the core `Peri` module to support Ecto integration
- Added `Peri.Ecto` module for parsing Peri schemas into Ecto-compatible definitions
- Enhanced type system to support bidirectional conversion between Peri and Ecto types

## [0.3.3] - 2025-06-10

### Added

- Support for 2-arity callbacks in `:cond` and `:dependent` types (#28)
  - 1-arity callbacks receive the root data structure (backward compatible)
  - 2-arity callbacks receive `(current, root)` where:
    - `current` is the data at the current validation context (e.g., list element being validated)
    - `root` is the entire root data structure
  - This is especially useful when validating elements within lists, allowing callbacks to access the current element's data instead of the parent structure
  - MFA (Module, Function, Arguments) style callbacks also support 2-arity functions

## [0.3.1] - 2025-03-14

### Fixed

- Make `:either` behave consistently with `:oneof` for nested schemas (#21)

### Added

- New schema types for map and literal (#22)

## [0.2.11] - 2024-09-16

### Added

- ability to pass partial MFA (aka `{mod, fun}`) or complete MFA (aka `{mof, fun, args}`) to `:transform`, `:dependent` and `:default` directives

## [0.2.10] - 2024-09-16

### Added

- fixes for `0.2.10` [45300d3]
  - default values are also applied to nested schemas when the parent node is `nil`
  - all type schemas are treat as optional by default
  - allow types as valid schema definition
    - `:date`
    - `:time`
    - `:datetime`
    - `:naive_datetime`
    - `:pid`

## [0.2.8] - 2024-08-01

### Added

- handle structs as input data for schemas [859a0fd]
- support validate enumerable schemas on raw data structures (eg. `:list` type) [32aa540]

## [0.2.7] - 2024-07-28

### Added

- Support multiple dependencies for the `:dependent` type [1be99ef]
- `:cond` type receives "root data" and is treated as required by default [336316c]
- basic `Jason.Protocol` for `Peri.Error` (optional) [9031b1e]
- correctly pass "root data" to `:cond` and `:dependent` types [b79dfbd]
- allow usage of `:one_of` and `get_schema/1` [cb1b250]
- handle schemas definitions with string keys [266b5a2]

## [0.2.6] - 2024-06-27

### Added

- Data generation with based on `StreamData` provided as the `Peri.generate/1` function that receives a schema and returns a stream of generated data that matches this schema. [c85b972]

## [0.2.5] - 2024-06-22

### Added

- Numeric and String Validations: Implemented new validation types for numeric and string data, including regex patterns, equality, inequality, range, and length validations. This allows for more granular and specific data validations. [9bb797e]

## [0.2.4] - 2024-06-21

- Implemented new type `{type, {:default, default}}`. [a569ecf, 821935f]
- Implemented new type `{type, {:transform, mapper}}`. [785179d]

## [0.2.3] - 2024-06-18

### Added

- Implemented schema validation, bang functions, and improved error inspection. [fc061f0]

### Fixed

- Improved error handling and inspecting. [f4d504b, afb054e]

## [0.2.2] - 2024-06-17

### Added

- Native support for keyword lists. [9f8aaef]
- `conforms?/1` function. [9a39ed8]

## [0.2.1] - 2024-06-16

### Added

- Continuous Integration (CI) setup. [16cf116]

### Fixed

- Corrected mix.exs file for hex package. [af5a744]

## [0.2.0] - 2024-06-15

### Added

- Enhanced error handling features. [f4d504b, afb054e]

### Fixed

- Documentation updates in README and Hex docs. [4fd48ce]

## [0.1.4] - 2024-06-10

### Added

- Support for `any`, `atom`, `oneof`, and `either` types. [6a225f4]

## [0.1.2] - 2024-06-05

### Added

- Removed unknown fields from schema validation. [3fa79d4]
- Allowed custom, composable, and recursive schemas. [fd1f593]

### Fixed

- Support for string map keys. [1b6edef]

## [0.1.1] - 2024-06-02

### Added

- Support for `tuple`, `lists`, `enum`, and custom types. [7766adc]

## [0.1.0] - 2024-06-01

### Added

- Initial version of Peri with basic schema validation functionalities. [7044ea7]

[0.5.0]: https://github.com/zoedsoupe/peri/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/zoedsoupe/peri/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/zoedsoupe/peri/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/zoedsoupe/peri/compare/v0.3.1...v0.3.3
[0.3.1]: https://github.com/zoedsoupe/peri/compare/v0.2.11...v0.3.1
[0.2.11]: https://github.com/zoedsoupe/peri/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/zoedsoupe/peri/compare/v0.2.8...v0.2.10
[0.2.8]: https://github.com/zoedsoupe/peri/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/zoedsoupe/peri/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/zoedsoupe/peri/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/zoedsoupe/peri/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/zoedsoupe/peri/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/zoedsoupe/peri/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/zoedsoupe/peri/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/zoedsoupe/peri/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/zoedsoupe/peri/compare/v0.1.4...v0.2.0
[0.1.4]: https://github.com/zoedsoupe/peri/compare/v0.1.2...v0.1.4
[0.1.2]: https://github.com/zoedsoupe/peri/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zoedsoupe/peri/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zoedsoupe/peri/releases/tag/v0.1.0
