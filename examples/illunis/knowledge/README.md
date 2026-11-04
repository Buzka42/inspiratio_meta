# Knowledge bank

Seed notes for the expert council (RAG). Each folder is an expert id from `server/src/council/experts.js`:
`diet`, `training`, `breath_stress`, `sleep_lifestyle`. Only these folders are ingested.

`server/scripts/ingest-knowledge.mjs` reads `knowledge/<expert>/*.md`, chunks them and upserts them into the
Vectorize index `illunis-knowledge`. Check the files with `cd server && node scripts/ingest-knowledge.mjs --dry-run`.

## Note format

```
---
source_id: nhs-example            # [A-Za-z0-9_.-]{1,64}, unique inside the expert folder
title: "NHS: Page title"
url: https://...                  # the real https page the note is based on
licence: "Open Government Licence v3.0 (NHS website content)"
retrieved: 2026-10-25             # YYYY-MM-DD, the day the page was read
---
Body, 150-400 words, our own words.
```

## Rules

1. Write in your own words. Never paste source text.
2. Use only a page you actually fetched. Never invent a URL. If you could not read a source, do not write the note.
3. General wellbeing and health information only: no diagnosis, no medicine doses or prescriptions, no individual treatment advice, no numeric condition targets for the user.
4. Record the licence in the frontmatter and add the source to the attribution list below.
5. Keep one source per note. The body ends with a short source line.

## How to add a note

1. Read the public page. Check its licence (look for the Open Government Licence, a US government work, or a CC licence on the page).
2. Add `knowledge/<expert_id>/<source_id>.md` with the frontmatter above.
3. Run the dry run and fix any reported problem.
4. Add the source to the list below if it is a new publisher.
5. Re-run the ingest script with Cloudflare credentials to update the index.

## Attribution

- **NHS website** (nhs.uk, NHS England and related NHS content): Open Government Licence v3.0, https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/. Contains public sector information licensed under the OGL v3.0. Third-party material on those pages (photographs, charity content) is excluded and was not used. Summaries here are our own and are not endorsed by the NHS.
- **MedlinePlus**, US National Library of Medicine (medlineplus.gov): US government work, public domain, except third-party material. Cited as the source in each note.
- **NIH institutes**: NCCIH, NIMH and NHLBI (nccih.nih.gov, nimh.nih.gov, nhlbi.nih.gov): public domain unless a page says otherwise (images are excluded). Cited in each note.
- WHO and CDC pages, and PubMed Central open-access reviews, are planned sources. None are in the seed set yet (the CDC site refused automated fetches on 2026-10-25, and PMC notes need a per-article CC licence check).

## Retrieval notes (2026-10-25)

- nhs.uk began returning HTTP 403 to automated requests partway through retrieval. Notes for about 55 NHS pages were read from the Internet Archive copy of the NHS page (web.archive.org snapshot, the same nhs.uk text) and the rest directly. The `url` in each note is the original nhs.uk address. Some NHS condition pages have since been reorganised into sub-pages, so the sub-page text (symptoms and so on) was read directly where noted in the note's source line.
- Wording on the NHS site changes. The NHS "PCOS" address now shows the condition as PMOS, and the note says so.
- Every note should be re-checked against the live page when the bank is next refreshed.
