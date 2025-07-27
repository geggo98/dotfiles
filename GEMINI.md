# Commit Style Guide

This project follows the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification. This provides a standardized format for commit messages, which makes it easier to understand the history of the project and to automate tasks like generating changelogs.

## Format

Each commit message consists of a **header**, a **body** and a **footer**.

```
<type>(<scope>): <subject>
<BLANK LINE>
<body>
<BLANK LINE>
<footer>
```

The **header** is mandatory and has a special format that includes a **type**, a **scope** and a **subject**.

### Type

The type must be one of the following:

*   **feat**: A new feature
*   **fix**: A bug fix
*   **docs**: Documentation only changes
*   **style**: Changes that do not affect the meaning of the code (white-space, formatting, missing semi-colons, etc)
*   **refactor**: A code change that neither fixes a bug nor adds a feature
*   **perf**: A code change that improves performance
*   **test**: Adding missing tests or correcting existing tests
*   **build**: Changes that affect the build system or external dependencies (example scopes: gulp, broccoli, npm)
*   **ci**: Changes to our CI configuration files and scripts (example scopes: Travis, Circle, BrowserStack, SauceLabs)
*   **chore**: Other changes that don't modify src or test files
*   **revert**: Reverts a previous commit

### Scope

The scope provides contextual information and is contained within parenthesis, e.g., `feat(parser):`. It can be anything specifying the place of the commit change.

### Subject

The subject contains a succinct description of the change:

*   use the imperative, present tense: "change" not "changed" nor "changes"
*   don't capitalize the first letter
*   no dot (.) at the end

## Body

The body is used to provide additional context and information about the code changes. It should be used to explain *what* and *why* vs. *how*.

## Footer

The footer is used to reference issues or pull requests that the commit closes or relates to.

## Example

```
feat(home): Add alias for Gemini CLI

This commit adds a new alias `g` for the Gemini CLI to make it easier to use.
```
