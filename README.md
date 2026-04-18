# Zondo: MONDO Ontological Terms in Postgres Full-Text Search
<!-- badges: start -->
[![Project Status: WIP – Initial development is in progress, but there has not yet been a stable, usable release suitable for the public.](https://www.repostatus.org/badges/latest/wip.svg)](https://www.repostatus.org/#wip)
<!-- badges: end -->

> [!CAUTION]  
> Still a work in progress.

Extracts & transforms [MONDO](https://www.ebi.ac.uk/ols4/ontologies/mondo) ontological terms and their synonyms to generate a [`.ths`](http://www.sai.msu.su/~megera/oddmuse/index.cgi/Thesaurus_dictionary) file for use as a Postgres Full-Text Search (FtS) [thesaurus](https://www.postgresql.org/docs/current/textsearch-dictionaries.html#TEXTSEARCH-THESAURUS) configuration. 

## 1. Usage

### 1.1. Prerequisites

1. Download the MONDO JSON terms [here](https://mondo.monarchinitiative.org/pages/download/) or [here](https://www.ebi.ac.uk/ols4/downloads). 

2. Download the most recent Zondo release [here](https://github.com/JackScanlon/Zondo/releases).

### 1.2. Using the executable

#### 1.2.1. Building a Thesaurus

After installation of the Zondo executable, a thesaurus can be built for a given MONDO release by running the following command:

```sh
zondo build --input /path/to/mondo.json --output /path/to/en_ontology.ths 
```

Where `--input` describes the path to the MONDO JSON file and `--output` specifies where the thesaurus should be generated.

#### 1.2.2. Command-Line Interface

```bash
zondo
Extract & transform ontological terms for Postgres Full-Text Search.

Usage:
	zondo {command} [flags]

Available Commands:
	* version   Display the program version and exit.
	* build     Build a PGXS thesaurus for a given MONDO release.

Flags:
	-h, --help Display this help text and exit
```

## 2. Development

### 2.1. Prerequisites
> [!WARNING]  
> Please ensure the compiler version matches the one used by this project, see [`.zigversion`](./.zigversion) for more information.

1. Install [Zig](https://ziglang.org/learn/getting-started/).

2. Install [Docker](https://docs.docker.com/engine/install/).

### 2.2. Getting Started

#### 2.2.1. Quick Start

1. Install [2.1. Prerequisites](#21-prerequisites).

2. Clone this repository.

3. Run `zig build` (or use the VSCode `Build Debug` task if applicable).

#### 2.2.2. Example Release Commands

> [!TIP]  
> See: https://ziglang.org/learn/build-system/

| Type        | Command                                                   |
|:-----------:|:----------------------------------------------------------|
| Build       | `zig build -Doptimize=ReleaseFast -Dstrip`                |
| Build & Run | `zig build run -Doptimize=ReleaseFast -Dstrip -- version` |

----

### Todo

Temporary tracker:
- [x] Implement CLI functionality
- [ ] Consider generating [PGXS](https://www.postgresql.org/docs/current/extend-pgxs.html) extension install package via templating
- [ ] Add GH workflow for CI/CD/release & linting
