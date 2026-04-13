# Git Identity Setup for Volantic Systems Repos

Run these steps once per machine (Windows or Linux) to ensure all VolanticSystems repos
use the correct commit identity automatically.

## What This Does

Git's `includeIf` feature detects when a repo's remote URL contains `VolanticSystems`
and automatically overrides the commit author name and email. No per-repo configuration
needed. Works regardless of where the repo is cloned on disk.

## Setup (All Platforms)

### Step 1: Create the identity file

Create a file called `.gitconfig-volantic` in your home directory with this content:

```
[user]
	name = Volantic Systems
	email = git26@volantic.systems
```

**Windows:** `C:\Users\<you>\.gitconfig-volantic`
**Linux/Mac:** `~/.gitconfig-volantic`

### Step 2: Add the conditional include to your global gitconfig

Open your global `.gitconfig` (same directory as above) and add this block at the end:

```
[includeIf "hasconfig:remote.*.url:**/VolanticSystems/**"]
	path = ~/.gitconfig-volantic
```

That's it.

## One-Liner Versions

**Linux/Mac (bash):**

```bash
cat >> ~/.gitconfig-volantic << 'EOF'
[user]
	name = Volantic Systems
	email = git26@volantic.systems
EOF

git config --global --add includeIf."hasconfig:remote.*.url:**/VolanticSystems/**".path "~/.gitconfig-volantic"
```

**Windows (PowerShell):**

```powershell
@"
[user]
	name = Volantic Systems
	email = git26@volantic.systems
"@ | Set-Content "$env:USERPROFILE\.gitconfig-volantic"

git config --global --add includeIf."hasconfig:remote.*.url:**/VolanticSystems/**".path "~/.gitconfig-volantic"
```

## Verify

From inside any VolanticSystems repo:

```bash
git config user.email
# Should output: git26@volantic.systems

git config user.name
# Should output: Volantic Systems
```

From a non-VolanticSystems repo, your default identity is unchanged.

## Requirements

- Git 2.36 or later (released April 2022)
- Check with `git --version`
