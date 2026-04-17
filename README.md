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

### 1.2. Building a Thesaurus

> [!NOTE]  
> **TODO**

## 2. Development

### 2.1. Prerequisites
> [!WARNING]  
> Please ensure the compiler version matches the one used by this project, see [`.zigversion`](./.zigversion) for more information.

1. Install [Zig](https://ziglang.org/learn/getting-started/).

2. Install [Docker](https://docs.docker.com/engine/install/).

### 2.2. Getting Started

> [!NOTE]  
> **TODO**

----

### Todo

Temporary tracker:
- [ ] Implement CLI functionality
- [ ] Consider generating [PGXS](https://www.postgresql.org/docs/current/extend-pgxs.html) extension install package via templating
- [ ] Add GH workflow for CI/CD/release & linting
