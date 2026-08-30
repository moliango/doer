# Frontend Development Guidelines

> Best practices for frontend development in this project.

---

## Overview

This directory contains guidelines for frontend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | Module organization and file layout | To fill |
| [Component Guidelines](./component-guidelines.md) | Component patterns, props, composition | To fill |
| [Hook Guidelines](./hook-guidelines.md) | Custom hooks, data fetching patterns | To fill |
| [State Management](./state-management.md) | Local state, global state, server state | To fill |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | To fill |
| [Type Safety](./type-safety.md) | Type patterns, validation | To fill |
| [Build & Dependencies](./build-and-dependencies.md) | Tuist regeneration, SPM dedupe, verification norm | Filled |
| [App Extensions](./app-extensions.md) | Widget App Group snapshot, APNs silent wake, Home connectivity, quote-reply | Filled |
| [FluxDo Porting](./fluxdo-porting.md) | Reference repo, porting rules, Discourse endpoint contracts | Filled |
| [Image Loading](./image-loading.md) | Memory/disk/network paint, gallery hero flight | Filled |
| [Composer](./composer.md) | Image paste upload, Pangu, poll builder, hold-to-talk, PM preview, experimental reply WYSIWYG | Filled |
| [Topic Find Filter](./topic-find-filter.md) | In-topic find bar, `filterUsername` / 只看此人 | Filled |
| [Cooked Blocks](./cooked-blocks.md) | `ContentBlock.policy`, voice wrap, exhaustive switch | Filled |
| [Topic Preview](./topic-preview.md) | Long-press morph, search + Home targets | Filled |
| [GitHub Proxy](./github-proxy.md) | Update check mirror prefix | Filled |

---

## Quality Check

Before finishing frontend work:

- [ ] `make generate` if Swift files or `Project.swift` / entitlements changed
- [ ] `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- [ ] Do not boot Simulator unless the owner asked
- [ ] Widget / App Group / APNs / deep-link contracts match [App Extensions](./app-extensions.md)
- [ ] Cookie login must not add Discourse `push_url` / User API Key flows

---

## How to Fill These Guidelines

For each guideline file:

1. Document your project's **actual conventions** (not ideals)
2. Include **code examples** from your codebase
3. List **forbidden patterns** and why
4. Add **common mistakes** your team has made

The goal is to help AI assistants and new team members understand how YOUR project works.

---

**Language**: All documentation should be written in **English**.
