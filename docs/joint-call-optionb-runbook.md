# Joint-Call Option B — Production Run & Monitoring Runbook

> **✅ COMPLETE (2026-07-06).** Driver `12421984` finished exit 0 on 2026-07-01 (6d 8h, beat the 7d wall). Cohort VCF `results/life_legacies_jun2026.vcf.gz` = 233 GB, **1551 samples**, validated. Remaining: copy off autodelete to permanent storage (owner: Ryan). Full outcome in §7 (07-06 entry); reusable takeaways in **§8 Lessons learned**.

**Date:** 2026-06-09 (run complete 2026-07-01)
**Driver:** `joint-call-gvcfs/run.sh` (full cohort, Option B)
**Companion docs:** `joint-call-test-plan.md` (smoke-test gate, now PASSED), `joint-call-progress.md`, `joint-call-optimization-plan.md`

---

## 0. What we're doing

Run the full **1566-sample** joint call with Option B = **reblock every gVCF → scatter into ~2 Mbp intervals (~1558 of them) → GenomicsDBImport → GenotypeGVCFs → bcftools concat** into one cohort VCF.

This replaces the old 10 Mbp / non-reblocked run (`12027677`) that died at the 7-day wall on variant-dense genotype stragglers. The chr22 smoke test (job `12159703`, 2026-06-08) validated the new code end-to-end: 58/58 tasks COMPLETED, 0 retries, reblock shrank gVCFs to 10–32% of input, final VCF had exactly 5 samples and 156k chr22 variants.

**Decision log (2026-06-09):**
- **Not** staging raw gVCFs onto VAST. Inputs read from `archive` (Lustre). Rationale: archive is only read once per sample during that sample's reblock task; afterward everything is on VAST/autodelete and immune to archive migration. Worst case if archive goes slow mid-run = reblock phase stretches, run does not fail.
- Final cohort VCF **must be copied to permanent group storage** at the end — autodelete is purgeable scratch (see §5).

---

## 1. Pre-launch checklist

- [x] **Input read access.** Checked 2026-06-09: all 1566 gVCFs + `.tbi` readable, 0 missing. (Paths point at `grp_life_and_legacy_storage`, NOT `storage2`, but access is fine.)
- [x] **Capacity — OK.** Measured 2026-06-09: raw gVCF total **13.11 TB** (stays on `archive`, NOT staged, so does NOT count against autodelete). autodelete free = **19 TB**. Reblocked outputs publish `mode: 'link'` (hard link → no duplication between `work/` and `results/reblocked/`), so reblocked costs ~2.5–4.6 TB once. Projected peak `work/` (reblocked + ~1558 GDB databases + genotype intermediates + ~100+ GB cohort VCF) ≈ 10–13 TB, fits in 19 TB. Re-check with `df -hT .` periodically during the run.
- [x] **run.sh params** confirmed 2026-06-09: `diff run-old.sh run.sh` (ignoring comments) shows ONLY `--reblock` added, `--interval_bp 10000000→2000000`, cohort `may14→jun2026`. No `--test_contig`.
- [x] **HPC env block untouched** vs run-old.sh — confirmed byte-identical (conda hook, apptainer, image cache, ref/input paths, Slurm header).

## 2. Launch (fresh from-scratch start)

`-resume` is correct on a wiped work dir. Do **NOT** `-preview` first — a bare `-resume` after `-preview` poisons the Nextflow cache.

```bash
# Wipe prior cache so all hashes are fresh (Option B changes everything anyway)
rm -rf /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/work/* \
       /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs/.nextflow \
       /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs/.nextflow.log*

cd /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs
sbatch run.sh
```

Record the job id: **12162794**  (launched 2026-06-09 ~08:5x on m8-20-4, driver wall = 7 days).
First-minute check PASSED: executor submitting REBLOCKGVCF tasks, `9 of 1566` reblocks done early, full genome (no test_contig), phases correctly gated.

---

## 3. Expected timeline & phases

The pipeline runs in three serial phases (GDB can't start until ALL samples are reblocked):

| Phase | What runs | Concurrency | Expected wall | Notes |
|---|---|---|---|---|
| **1. Reblock** | 1566 REBLOCKGVCF | up to 64 (`queueSize`) | **~2–2.5 days** (range 1.5–3) | The long pole. Reads from archive. ~2,500 task-hours / 64 slots ≈ 39h if slots stay full. |
| **2. GDB** | ~1558 GENOMICSDBIMPORT | up to 64 | hours | Test: 6–20s/task at 5 samples; scales with sample count but stayed light. |
| **3. Genotype + concat** | ~1558 GENOTYPEGVCFS → 1 CONCAT | up to 64 | **UNKNOWN** | Genotype cost scales with 1566 samples — the one number the test could not measure. This is the real risk to the 7-day wall. |

**Driver wall is 7 days.** If reblock eats ~2.5 days and genotype is slow, it could get tight. Watch genotype closely (§4).

---

## 4. Monitoring plan — what to check, when

Set `JOB=<driver_jobid>` and `RUN=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs`.

### 4.1 First 10 minutes (did it start cleanly?)
```bash
squeue -u $USER                                   # driver running + REBLOCK tasks appearing
tail -30 $RUN/logs/joint-call-gvcfs.$JOB.out      # expect 'executor > slurm' + REBLOCKGVCF submitting
```
Red flags: driver exits immediately, "no such file" on inputs, 0 tasks submitted.

### 4.2 Daily during reblock (phase 1, ~days 1–3)
```bash
# progress line from the driver log
grep -E 'REBLOCKGVCF|process_reblock' $RUN/logs/joint-call-gvcfs.$JOB.out | tail -3
# how many reblock tasks done vs running vs pending
squeue -u $USER -o '%.18i %.30j %.8T %.10M' | grep -ic RUNNING
# any task failures / retries (exit 140 = walltime, 247 = OOM)
sacct -j $JOB --format=JobID,JobName%20,State,ExitCode,Elapsed -P | grep -Ei 'FAILED|TIMEOUT|OUT_OF_ME|140|247'
```
**Checkpoint A — when reblock hits ~100% done:** verify count of reblocked outputs, then phase 2 should auto-start.
```bash
ls /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/results/reblocked/*.reblocked.g.vcf.gz | wc -l   # want 1566
```

### 4.3 During genotype (phase 3 — the risk window)
```bash
# pull realtime of completed genotype tasks from the live trace
TR=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/results/pipeline_info/trace.txt
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i} $(h["process"])~/GENOTYPEGVCFS/ && $(h["status"])=="COMPLETED"{print $(h["realtime"])}' "$TR" | sort | tail
```
**Checkpoint B — first ~50 genotype tasks done:** look at the slowest realtime.
- If slowest genotype task ≪ 48h → ladder is fine, optionally trim A1 later for backfill.
- If any genotype task approaches its A1 wall (48h) → it will retry at A2 (96h) / A3 (168h=cap). A task needing >168h **cannot finish** — that's the dead-end failure mode. Escalate (smaller intervals or split the dense region) before burning the 7-day driver wall.

### 4.4 At the wall / on driver END email
- `--mail-type=FAIL,END` emails you. On END, check it actually finished vs hit the wall:
```bash
sacct -j $JOB --format=JobID,State,Elapsed,ExitCode -P
grep -E 'Completed at|Succeeded|Duration' $RUN/logs/joint-call-gvcfs.$JOB.out | tail
```
- If the driver hit 7 days mid-genotype: **resume** is cheap — re-`sbatch run.sh` (do NOT wipe work/, do NOT -preview). It picks up completed tasks from cache. Time directives aren't hashed, so any ladder tweaks between resumes are safe.

---

## 5. Success criteria & post-run

On clean completion:
```bash
OUT=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/results
module load bcftools
bcftools query -l $OUT/life_legacies_jun2026.vcf.gz | wc -l     # want 1566
bcftools view -H $OUT/life_legacies_jun2026.vcf.gz | head        # variants present, all contigs
# trace: every task COMPLETED, zero exit 140/247
awk -F'\t' 'NR>1{print $5}' $OUT/pipeline_info/trace.txt | sort | uniq -c
```

**Then copy the cohort VCF off scratch to permanent storage** (autodelete is purgeable):
```bash
cp $OUT/life_legacies_jun2026.vcf.gz{,.tbi}  <PERMANENT_GROUP_STORAGE>/   # NOT under nobackup/
```

---

## 6. Known risks / decisions

- **Genotype walltime is unmeasured at 1566 samples.** Biggest unknown. Mitigation: generous ladder (48/96/168h), Checkpoint B early-warning, optional §3.B calibration from the test plan (one dense MHC slice) if you want a data point before committing.
- **Archive migration mid-run.** Accepted. Only affects reblock reads; stretches phase 1, doesn't fail the run.
- **Capacity.** Verify raw + reblocked + work/ fit in 19 TB (§1).
- **Downstream still missing.** Pipeline stops at a raw cohort VCF. VQSR/VETS filtering + QC (relatedness, PCA, sex check, APOE) not built — see optimization-plan §6. Gates analysis, separate effort.

---

## 7. Check-in log

### 2026-06-11 — day 2.4, Phase 1 (reblock) ~81% done
- Driver `12162794` RUNNING, **2d10h / 7d** wall. Reblock **1272/1566 (81%)**, 65 tasks running, **0** failed/TIMEOUT/OOM dead-ends, 11 retries (all recovered; ladder bumped slow tasks 8h→16h). Disk 3.3 TB / 20 TB — fine.
- **Archive migration is now live** (cluster banner, "much slower"). This is the §6 risk materializing: reblock tasks running 5–7h against the 8h wall, hence the retries. Reblock will land ~3–3.5 days vs the ~2–2.5 day budget — eats buffer for the unmeasured genotype phase.
- **Completion rate ~20 reblocks/hr** (steady). 290 remaining → **reblock done in ~14h**.
- **Phase-start ETAs from here:** GDB (phase 2) ≈ **+14h**; GenotypeGVCFs (phase 3, the Checkpoint-B risk window) ≈ **+18–24h**. Next check-in best timed to genotype start (~+18–24h).

### Duplicate-sample handling (decided 2026-06-11)
Two kinds, different intervention points:
- **Identical sample-NAME** (same `SM` header in two gVCFs) → **GenomicsDBImport hard-crashes** at phase-2 start. Self-announcing. *Checked 2026-06-11: no duplicate filenames, SM names unique so far → unlikely.*
- **Biological duplicate** (same person, two IDs — e.g. a `WA####` vs one of the 18 `NEAR_####`) → pipeline does **not** catch it; both become columns in the cohort VCF.
  - Does **not** corrupt the joint call — only adds a column + slightly perturbs cohort AF / VQSR training. Per-sample genotypes for everyone else are unaffected.
  - **If duplicate IDs are KNOWN now:** drop **before GDB** (window = next ~14h). Remove the ID from `params.input` and `sbatch run.sh` to resume (no wipe). `sample_map.tsv` is rebuilt from the channel each run (`main.nf:77-79`), so the dropped sample falls out automatically; reblock stays cached.
  - **If duplicates must be DETECTED:** do **not** intervene mid-run. Finish the call, detect via kinship in QC (KING/plink; duplicate pairs ≈ kinship 0.5 / near-identical IBS), then drop the column post-hoc: `bcftools view -s ^WA0101 cohort.vcf.gz`. Instant, reversible — vs rebuilding ~1558 GDB databases to drop one sample.
  - **Recommendation:** unless an authoritative duplicate list exists right now, let the run finish and remove in QC.

### 2026-06-16 — Phase 2 CRASHED on duplicate sample; CSV fixed, ready to resume
**Status: driver `12162794` FAILED Jun 12 21:36 (3d08h elapsed, exit 1 — hard error, NOT the wall). Queue empty.**

- **Phase 1 (reblock) completed** — all 1565 unique samples reblocked and cached in `work/`. Reblock took the full ~3 days as the 06-11 entry predicted (archive migration slowdown).
- **Phase 2 (GDB) died on the very first task** (`chr1:1-2000000`, work dir `73/368899…`): `GenomicsDBImport` → `A USER ERROR ... Found two mappings for the same sample: WA0004`. This is the §7 "identical sample-NAME → GDB hard-crashes" failure mode. It self-announced exactly as documented.
- **Why the 06-11 dup check missed it:** the check looked at filenames + SM headers. The actual dup was the *same* gVCF listed under **two archive directory layouts**, so it produced two distinct work dirs but the same `WA0004` SM name:
  - row 646 (outlier): `…/batch1/WA0004/`**`results/`**`variant_calling/haplotypecaller/WA0004/WA0004.haplotypecaller.g.vcf.gz`
  - row 647 (cohort-standard): `…/batch1/WA0004/variant_calling/haplotypecaller/WA0004/WA0004.haplotypecaller.g.vcf.gz`
  - Both source files are **byte-identical** (8,145,068,660 bytes). WA0004 was the **only** duplicate in the 1566-row sheet. The `/results/` layout was used by exactly 1 of 1566 rows.

**Fix applied 2026-06-16:**
- Removed the outlier row 646 from `…/joint-vcf-results/life_legacy_sample_sheet-combined.csv`. Sheet now **1565 rows, 0 duplicate sample IDs**, WA0004 kept on the cohort-standard path (its reblock = work dir `c9/8050c0…`, already complete + cached).
- Backup of the pre-fix sheet: `life_legacy_sample_sheet-combined.csv.bak-20260616-predupfix`.

**To resume (do this — no wipe, no -preview):**
```bash
cd /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs
sbatch run.sh
```
`sample_map.tsv` rebuilds from the channel with 1565 unique entries (`main.nf:77-79`); all 1565 reblocks stay cached, so the run jumps straight to GDB → GenotypeGVCFs → concat. **Phase 3 (genotype) is the still-unmeasured risk window — watch Checkpoint B (§4.3) once genotype tasks start.**

### 2026-06-17 — Run silently ABORTED on a transient FS hiccup; config hardened + resumed
**Status: caught the resumed driver `12333098` (run `chaotic_minsky`) in a zombie/aborting state. Now resumed clean as `12342087` (run `angry_minsky`), 64 slots full, in the genotype phase.**

What happened:
- The 06-16 fix worked: driver `12333098` resumed Jun-17 02:16, reblocks all cached, GDB ran to **279/1559 intervals**. Then at **14:35:40** GDB interval **(1177)** was logged as *"terminated by external system"* and the whole run was **cancelled** (`Execution cancelled -- Finishing pending tasks before exit`). It then sat a **zombie for ~2.5h** — idling on 6 in-flight genotype tasks while 1495 queued tasks would never be submitted. No FAIL email yet because the driver hadn't exited.
- **Root cause = config flaw, not a real task failure.** Nextflow couldn't read 1177's `.exitcode` within the 270s default (`exitStatusReadTimeoutMillis: 270000; delta: 274922` — overran by **~5 seconds**), so `task.exitStatus` was **null**. The errorStrategy `{ task.exitStatus in ((130..145)+104+247) ? 'retry' : 'finish' }` doesn't match null → fell through to **`finish`** → aborted the entire multi-day run. The slow `.exitcode` flush is the §6 archive-migration "much slower" FS risk hitting the control plane. With ~1559 genotype tasks each flushing `.exitcode` to the same stressed FS, this **would have recurred**.

Fix applied (both cache-safe — directives/executor settings aren't hashed, so 1551 reblocks + 279 GDBs stayed cached):
- `conf/slurm.config` (the effective one under `-profile slurm`) **and** base `nextflow.config`: errorStrategy now retries on **null** exit too — `{ (task.exitStatus == null || task.exitStatus in ((130..145)+104+247)) ? 'retry' : 'finish' }`.
- `conf/slurm.config`: added `executor { exitReadTimeout = '20 min' }` (was 270s) so slow `.exitcode` flushes aren't misread as failures — the targeted fix for this exact event.
- Cancelled zombie driver `12333098` + its 6 orphaned genotype tasks (couldn't be cache-reused by a resume anyway), then `sbatch run.sh`.

Resume verified: `angry_minsky` board = REBLOCK 1551/1551 cached ✔, GDB 279 cached (~1280 to go incl. 1177 rerunning), GENOTYPEGVCFS submitting, 64 slots full (62 genotype + 2 GDB), driver wall fresh 7d.
- **Checkpoint B (§4.3) is now LIVE and still the real risk** — genotype walltime at 1565 samples remains unmeasured. Next check-in: pull the slowest GENOTYPEGVCFS realtimes once ~50 have COMPLETED; if any nears its 48h A1 wall, escalate per §4.3 before burning the driver wall.

### 2026-06-21 — Two more aborts, then hit the REAL wall: a 2,000,000-inode quota. DECISION NEEDED (see options below).
**Status: everything STOPPED. Queue empty. Reblock (the 3-day part) is safe + cached. ~229 genotype intervals will need re-running no matter what. Inodes at 61% used (~780K free). Pipeline is BLOCKED pending an architecture decision — pick an option below before relaunching.**

What happened (three failures, same underlying cause = the migration-stressed VAST filesystem):

1. **Genotype walltime risk is RESOLVED (good news).** Completed GENOTYPEGVCFS realtimes top out ~19–23h, well under the 48h A1 wall. Checkpoint B passes; no ladder change needed.

2. **Abort #1 — exit 1 (driver `12361716`, Jun-21 06:21).** GENOTYPEGVCFS task 1382 (`chr20:28000001-30000000`) died mid-traversal. Not OOM (MaxRSS 3.6 GB / 72 GB), not walltime (36 min). Smoking gun: its `.command.err` has a **block of NUL bytes** where the error should be = the shared FS failed to flush writes. Coincided with a cluster-wide FS event (08:00–08:30: dozens of tasks hit `.exitcode` read-timeouts, even the 20-min one). Same root cause as the 06-17 null abort, but it surfaced as a clean **exit 1**, which the errorStrategy did NOT retry → `finish` → whole run aborted.
   - **FIX APPLIED (kept):** errorStrategy now also retries exit 1, in both `conf/slurm.config` and `nextflow.config`: `{ (task.exitStatus == null || task.exitStatus in ((130..145)+104+247+1)) ? 'retry' : 'finish' }`. (exit 1 is also GATK's USER ERROR code, so a genuinely deterministic error now burns maxRetries before finishing — accepted.)

3. **THE REAL WALL — 2,000,000-inode (file-count) quota, 100% full.** On resume the driver couldn't even write `.command.run`: `Disk quota exceeded`. `df` shows only 5/20 TB used, but `df -i` = **2,000,000 / 2,000,000 inodes**. Cause: each **GenomicsDBImport database = ~2,282 files**; 875 built ≈ 1.997M files ≈ the entire quota. **All 1,559 databases would need ~3.56M files — they physically cannot coexist under a 2M cap.** The byte-capacity check in §1 never looked at inodes; this is the blind spot. This wall will recur on EVERY launch until the architecture changes.

4. **Abort #2 — the workaround backfired (exit 2).** Tried: delete already-consumed databases + a background "janitor" (`gdb_janitor.sh`) to keep deleting consumed ones + throttle GDB (`maxForks` 20→12). It freed inodes (deleted 229 databases) BUT:
   - **Deleting a database breaks Nextflow's cache for that interval** — the consuming genotype re-runs (my earlier "cache-safe" claim was WRONG). ~229 deleted → ~217 genotypes lost cache (367 done → only 150 still cached).
   - **The janitor races the re-runs:** it reads a *prior* run's stale `.exitcode==0`+`.vcf.gz` and deletes a database that the *current* re-running genotype still needs → `A USER ERROR: Couldn't read .../callset.json ... It doesn't exist` → **exit 2** (also not retried) → aborting again.
   - Conclusion: **the delete-databases-to-fit approach is too fragile** (cache invalidation + deletion races corrupting state). Abandoned.

**Dead ends already ruled out (don't re-try these):**
- **Node-local scratch for the database** — `/tmp` is 209 GB (186 free), fine for ONE task (~18 GB db) but blows out when ~16 tasks pack a 64-core node (~320 GB). This is why `resources.config` sets `scratch=false`. Off the table.
- **`--genomicsdb-shared-posixfs-optimizations true`** — already ON in the module; databases are still ~2,282 files. Does not reduce the count enough.

**DECISION NEEDED — pick one, then relaunch:**

- **Option A — Raise the inode quota (RC ticket), then stop deleting.** Ask RC to bump the autodelete file-count quota 2M → ~4M (run needs ~3.6M for all 1,559 databases at once). Then delete `gdb_janitor.*`, keep all databases, resume normally. **Zero pipeline-logic change, no deletion races, normal resume.** Re-runs only the ~229 already-deleted intervals. Downside: depends on RC granting it; the many small files still churn the stressed FS, but the exit-1/2/null retry-hardening absorbs those hiccups. *(Cleanest IF the quota can be raised.)*
- **Option B — Fuse GDB+genotype into one shared-FS task that `rm -rf`s its own database right after genotyping.** No admin needed; robust regardless of quota. Standing files stay ~320K (concurrent tasks only). Re-runs all GDB+genotype; needs code changes (combine the two modules) + a quick chr22 re-test. *(Self-sufficient fallback if RC won't budge.)*
- **Option C — Test `--consolidate` first.** GenomicsDBImport's `--consolidate` merges TileDB fragments into fewer files. One ~50-min build verifies whether it cuts the ~2,282 files/db enough to fit all 1,559 under 2M. If yes → a one-line fix (keep architecture, no quota, no fuse). If no → fall back to A or B.

**Repo state left for you (all cache-safe; nothing hashed changed):**
- `conf/slurm.config`, `nextflow.config`: errorStrategy retries exit 1 too (KEEP regardless of option).
- `conf/resources.config`: GENOMICSDBIMPORT `maxForks` 20→12 (only matters if databases stay on shared FS; revisit per chosen option).
- `gdb_janitor.sh` + `gdb_janitor.slurm`: the janitor. **Has the race bug described above — do NOT run as-is.** Keep for reference or delete if going with A/quota.
- Nothing is running. Safe to leave overnight.

**My recommendation:** Option A if you can get the quota raised (least risk, no rewrite); otherwise B. Keep the exit-1 retry fix either way.

### 2026-06-25 — Option C (consolidate) was tried and is FATALLY SLOW. Run killed. Drop consolidate; go A or B.
**Status: Option C (`--consolidate true`) was applied 2026-06-24 (driver `12418415`, relaunched Jun-24 23:01). It solved inodes (each db ~90 files, 65% of cap) but consolidate is ~10h/task → GDB phase ~24 days vs the 7d wall. Killed the run today. BLOCKED on the A-vs-B decision again — but with consolidate ruled out.**

Pinpointed why it's slow (driver `12418415`, GDB task 0025 = chr1:48-50M, total 665.6 min):
- **Import = ~43 min (healthy). Consolidate = ~10h23m = 93% of the task.** Import does a few big batched sequential writes; consolidate does the opposite.
- **It's ~98% I/O-wait, not compute:** `sstat` on a running 11h GDB task showed **AveCPU = 10m50s** (~1.6% CPU util), ~3.8 GB total I/O.
- **Why:** consolidate single-threadedly rewrites **~70 tiny TileDB attribute arrays** (~500 B–60 KB each; the whole consolidated fragment is 433 KB) merging 32 fragments→1. Every tiny open/read/fsync/close pays the full round-trip latency of the **migration-degraded VAST NFS** (§6). Effective ~100 KB/s — pure per-op latency, not bandwidth/CPU. Not tunable (`--reader-threads` doesn't touch consolidate).
- Only 1 of 1559 dbs completed (11h5m, barely under the 12h A1 wall); the whole first wave of 30 was about to TIMEOUT and waste ~11h re-imports each.

**Conclusion: consolidate is fundamentally mismatched to the degraded FS. Drop it.** Both remaining options drop consolidate and restore the ~43-min import:
- **Option A** — raise inode quota (RC), keep ~2,282-file dbs, no consolidate. Needs RC to grant.
- **Option B (fuse)** — build db (no consolidate) → genotype → `rm -rf` in one task; standing file count bounded by concurrency, so needs **neither quota nor consolidate**. Self-sufficient; sidesteps the small-file pattern entirely. *(Now the front-runner.)*

**Killed today:** driver `12418415` + its 30 nf-GATK4_GENOMICSDBIMPORT tasks (`scancel`). Nothing running. Reblock (the 3-day part) still cached + safe. `--consolidate` still set in `modules/gatk4/genomicsdbimport.nf:37` + the maxForks=30 / 12-24-48h ladder in `conf/resources.config` — all to be reverted/replaced per chosen option before relaunch.

### 2026-06-25 (later) — Chose Option B. Fused module built, resources right-sized from data, inodes reclaimed, relaunching.
**Status: Option B implemented and validated. New module `GATK4_GDB_GENOTYPE` (import → genotype → `rm -rf gdb` in one task). Inodes cleaned 65%→5%. Relaunching the full cohort.**

**Decision: Option B (fuse), not A.** Self-sufficient (no RC quota grant needed), and the data made it a clear win.

**The module (`modules/gatk4/gdb_genotype.nf`, replacing the GENOMICSDBIMPORT + GENOTYPEGVCFS pair in `main.nf`):** one task builds the per-interval GenomicsDB (no `--consolidate`), genotypes straight from `gendb://`, then `rm -rf`s the workspace. The GDB is **never a Nextflow output**, which buys three things at once: (1) its ~2,282 files live only for the task's lifetime → peak inodes = `maxForks × 2,282`, bounded by *concurrency* not by the 1,559 intervals → the 2M-inode wall is gone; (2) deleting it **cannot** poison `-resume` (only the VCF is an output) → the 06-21 cache-loss failure mode is structurally impossible; (3) consolidate is dropped → the ~10h I/O-wait pass is gone, import back to ~1h.

**Resources right-sized from the 06-21 report (225 genotypes / 174 imports, 2 Mbp, 1565 samples):**
- Genotype realtime: median **14.7 h**, mean 14.3 h, p95 19 h, **max 26 h** (the "19–23h" in the 06-21 entry was the p95 tail, not typical). Import: **~0.9 h**.
- Peak RSS: import median **1.0 GB** / max 1.1 GB (GDBImport with `--bypass-feature-reader` streams — the old Xmx38g/48 GB slot was ~10× oversized); genotype median 3.4 GB / **max 4.5 GB**. Fused peak = max(...) ≈ 4.5 GB.
- → `process_jointcall`: **cpus=2** (genotype is single-threaded, the ~15h pole; import is I/O-bound), **memory 16/32/64 GB** (A1 = 3.5× observed max, Xmx≈11g; 3× lighter RAM than before), **time 48/96/168 h** (A1 = 1.8× the 27 h worst-case fused task; A3 = 7d cap).

**Concurrency `maxForks`/`queueSize` = 256** (`conf/resources.config` + `nextflow.config`). Throughput: 1,558 fused tasks × ~15.3 h mean ÷ 256 ≈ **3.9 d** (vs ~7.8 d at 128). Justification: the 06-21 run *actually sustained 128 concurrent* at the heavier 4cpu/72GB (peak-overlap analysis), so `pgr2` already held ~512 cores + ~9 TB RAM; the right-sized 2cpu/16GB task fits **256 in the same 512 cores at half the RAM (4 TB)** and backfills better. Inodes non-binding (256×2,282 ≈ 584K vs 1.9M free). FS load gentle: fusing self-throttles imports to ~`maxForks/15` ≈ 17 concurrent import phases at steady state. `pgr2` FairShare is low (0.043) so expect to *float* ~128–256; `-resume` covers any shortfall.

**Inode cleanup:** `cleanup-gdb-workspaces.sh --apply` removed **691** leftover `*_gdb` workspaces (the probe's "30" was a timed-out scan). `df -i`: 1,287,946 → **99,265 used (65% → 5%)**, 1.9M free. Reblock outputs untouched (script only matches `-type d -name '*_gdb'`).

**Config changes (committed separately):** `main.nf` (swap 2 process calls → `GATK4_GDB_GENOTYPE`); `conf/resources.config` (drop the two GDB/genotype `withName`+`withLabel` blocks → one `GATK4_GDB_GENOTYPE` `withName` maxForks=256 + `process_jointcall` label); `nextflow.config` (queueSize 128→256, submitRateLimit 40→60/min). Old `genomicsdbimport.nf`/`genotypegvcfs.nf` modules left on disk, unused.

**Validated** before launch via `nextflow config` + an **isolated** `-preview` (run from a scratch cwd so the real `.nextflow/history` — and the bare `-resume` — stays unpoisoned, per [[feedback-nextflow-resume]]): DAG built as REBLOCK → GDB_GENOTYPE → CONCAT over 1559 intervals. Relaunching `sbatch run.sh` (bare `-resume`, no `-preview` first; reblock 1551/1551 stays cached).

### 2026-07-01 — Option B is WORKING; down to the last 2 intervals, racing the driver wall.
**Status: driver `12421984` (Option B fused) RUNNING at 5d22h / 7d wall (~26h left). 1557/1559 fused GDB_GENOTYPE tasks COMPLETED; 2 stragglers still running + CONCAT pending. No aborts, no cache loss, inodes 7% — the architecture change held.**

Option B validated in production:
- **Reblock 1551/1551 cached ✔; GDB_GENOTYPE 1557/1559 COMPLETED; CONCAT not yet started.**
- **Inode wall gone:** `df -i` = **133K / 2M (7%)** — Option B's `maxForks × 2,282` bound worked exactly as designed. Disk 4.2/20 TB.
- **Zero of the old failure modes this run:** no null/exit-1/exit-2 aborts, no cache-loss, no janitor races. The retry-hardening + fuse structurally eliminated them.

**The remaining risk is pure straggler slowness, NOT a dead end.** Two variant-dense intervals genuinely need **>48h** to genotype even at 2 Mbp (the §4.3 straggler behavior, milder version):
- **Task 1455** — timed out at 48h A1 (exit 140), already **finished** on its 96h A2 retry.
- **Task 1506** — timed out at 48h A1, now on **96h A2**, elapsed ~1d5h.
- **Task 1483** — first attempt, 48h wall, elapsed ~1d11h (~13h of headroom before it also times out).

They all fit under the 96/168h ladder, so they *will* complete — the only question is whether they beat the **driver's** 7d wall (~26h left). Likely outcome: driver hits the wall with 1–2 stragglers still running.

**If the driver walls out (watch the FAIL/END email): resume, no wipe, no -preview.**
```bash
cd /home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-call-gvcfs
sbatch run.sh
```
All 1557 genotypes + reblocks stay cached; only the unfinished interval(s) re-run from scratch (the fused GDB isn't persisted), then CONCAT. If instead it **completed**: run §5 checks and **copy `life_legacies_jun2026.vcf.gz{,.tbi}` to permanent storage** (autodelete is purgeable).

### 2026-07-06 — ✅ DONE. Run COMPLETED clean (no wall hit). Cohort VCF produced and validated.
**Status: driver `12421984` COMPLETED, exit 0, on 2026-07-01 23:57. Everything finished before the 7d wall — the stragglers beat it. Final cohort VCF written and validated. Queue empty.**

Final tallies (from the driver log + `sacct`):
- **`Completed at: 01-Jul-2026 23:57:11 · Duration 6d 8h 48m` · driver exit `0:0`** — beat the 7d wall by ~15h.
- **REBLOCK 1551/1551 cached ✔ · GDB_GENOTYPE 1559/1559 ✔ (retries: 2) · CONCAT 1/1 ✔.**
- `Succeeded 1'560 · Cached 1'551 · Failed 2`. The "Failed 2" are the two dense-interval A1 (48h) timeouts (tasks 1483 & 1506 from the 07-01 entry) that **recovered on their 96h A2 retry** — not real failures. Genotype straggler risk (§4.3) fully absorbed by the 48/96/168h ladder; nothing hit the 168h cap.
- **Inodes 7% (132K/2M), disk 4.6/20 TB** at the end — the Option B `maxForks × 2,282` bound held all the way through.

Output validated (§5):
- `results/life_legacies_jun2026.vcf.gz` = **233 GB**, `.tbi` present (written 2026-07-01 23:56).
- `bcftools query -l | wc -l` → **1551 samples** (see sample-count note below). Variants well-formed (chr1 multiallelics + spanning-deletion `*` alleles as expected for a GATK joint call).

**Sample-count reconciliation — 1551 is CORRECT, not a silent drop.** §5 originally said "want 1566" (pre-dedup) and the 06-16 entry said "1565 unique". Final = **1551** because, *after* the reblock step, ~14 re-sequenced samples with a `_2` suffix (uncertain how to handle the resequenced replicate) were **deliberately removed from the sample sheet**. Evidence: `life_legacy_sample_sheet-combined.csv` = 1552 lines (1551 samples + header), and the final VCF's 1551 columns match it exactly. The `reblocked/` dir still holds **1565** cached gVCFs (the pre-removal set) — harmless leftovers; the 14 dropped ones simply were never fed into GDB. So sample sheet (1551) == cohort VCF (1551) == correct.

**Remaining action (owner: Ryan):** copy `life_legacies_jun2026.vcf.gz{,.tbi}` off autodelete to permanent group storage (NOT under `nobackup/`). Autodelete is purgeable scratch; the VCF has already sat there since 07-01. *Ryan is doing this copy manually.*

---

## 8. Lessons learned (what the next joint call should bake in from day one)

The run succeeded, but only after ~4 aborts and 3 relaunches over 3 weeks. Almost none of it was the genotyping itself — it was the interaction of GenomicsDB's file-count profile with a **migration-degraded VAST/NFS filesystem** and Nextflow's control plane. Bake these in next time:

1. **Check inodes, not just bytes, in the pre-launch capacity gate.** The single biggest miss (§1 only checked `df -h`). Each GenomicsDBImport database ≈ **2,282 files**; 1,559 of them = ~3.56M files, but the autodelete FS caps at **2,000,000 inodes**. Byte usage was only ~5/20 TB when we hit a 100%-full inode wall. **Always `df -i` up front** and compute `n_intervals × files_per_db` against the inode quota. [[autodelete-inode-cap]]

2. **Never make a GenomicsDB workspace a Nextflow output if you plan to delete it.** Deleting a published DB to reclaim inodes **invalidates `-resume` cache** for the consuming task (learned the hard way, 06-21) and, with a background janitor, **races the re-runs** into corrupt-state exit 2. [[deleting-gdb-breaks-nextflow-cache]] The clean fix is architectural, not operational →

3. **Fuse import → genotype → `rm -rf` into ONE task (the Option B winner).** The GDB lives only for the task's lifetime, is never an output, and is deleted in-task. This simultaneously (a) bounds peak inodes to `maxForks × files_per_db` (concurrency, not interval count) so the inode wall is structurally gone, (b) makes deletion **cache-safe** (only the VCF is an output), and (c) lets you drop `--consolidate`. This is the reusable pattern — start here next time, skip the separate-modules design entirely.

4. **`--consolidate true` is fatally slow on a latency-bound FS — do not use it to solve inodes.** It cuts a db to ~90 files but is **~10h/task, ~98% I/O-wait** (single-threaded rewrite of ~70 tiny TileDB arrays, each paying full NFS round-trip latency). Would have made the GDB phase ~24 days. Not tunable (`--reader-threads` doesn't touch it). (06-24/06-25.)

5. **Harden `errorStrategy` against control-plane flakiness on a stressed FS.** A degraded shared FS attacks Nextflow's bookkeeping, not just the science: slow `.exitcode` flushes → read timeout → `task.exitStatus == null`; failed write flushes → **NUL-byte `.command.err`** surfacing as a spurious **exit 1**. A strategy that only retries the "expected" codes falls through to `finish` and **aborts the whole multi-day run**. Ship with `{ (task.exitStatus == null || task.exitStatus in ((130..145)+104+247+1)) ? 'retry' : 'finish' }` **and** `executor { exitReadTimeout = '20 min' }` from the start. Trade-off accepted: a genuinely deterministic GATK USER ERROR (also exit 1) now burns `maxRetries` before finishing. [[nextflow-null-exitstatus-abort]]

6. **Duplicate-sample detection must compare more than filename + SM header.** GDB hard-crashes on a repeated `SM` name (self-announcing, phase-2 start). The one dup that slipped through (WA0004) was the *same* gVCF listed under **two different archive directory layouts** (`.../results/variant_calling/...` vs `.../variant_calling/...`) → two work dirs, same SM. Next time, also de-dup on **resolved/canonical file identity** (size + path-normalization), and decide the `_2` / resequenced-replicate policy *before* building the sheet.

7. **Right-size resources from observed telemetry, not guesses.** Post-hoc: import RSS ~1 GB (old 48 GB slot was ~10× oversized), genotype median ~15h / max ~27h / peak RSS ~4.5 GB. The fused task settled at **cpus=2, mem 16/32/64 GB, time 48/96/168h, maxForks 256** — half the RAM, double the concurrency, backfills better on a low-FairShare partition. Pull realtimes/RSS from `trace.txt` after any pilot and size the ladder to `A1 ≈ 1.8× worst-case`.

8. **Don't compute out of `archive`.** Reads-only-once-per-sample (reblock reading raw gVCFs from Lustre `archive`) was fine and never failed the run, but the archive migration ("much slower") is what degraded the whole FS environment and drove failure modes 1–5. Stage inputs onto the fast scratch FS before a long run if the migration is active.

**Net:** the science (reblock + 2 Mbp scatter + GenotypeGVCFs, ladder 48/96/168h) was sound the entire time. Every abort was infrastructure — inode quota + degraded FS. The Option-B fused module + retry-hardening is the durable answer; reuse it wholesale for the next cohort.
