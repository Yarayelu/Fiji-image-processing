// Batch ND2 Processor — Multi-series + Global Percentile Normalisation
// For each ND2 in the folder (handles multiple images per file):
//   1. Save every series as a separate TIF (MAX projection if z-stack)
//   2. Split channels → RGB TIFFs  (C1=GFP green | C2=CY5 red | C3=Brightfield grey)
//   3. Merge C1 + C2 → RGB TIFF
//   4. Montage: 1 column — Merged (top) / C1 GFP (middle) / C2 CY5 (bottom)
//   5. Measure whole-image mean fluorescence for C1 and C2 → CSV
//   6. Sample 5 spots, measure local mean fluorescence, save marked images
//
// NORMALISATION STRATEGY — two-pass global percentile stretch:
//   Pass 1: accumulate a pooled histogram across EVERY series for each channel.
//           Compute p0.1 and p99.9 from the pooled distribution.
//   Pass 2: apply that fixed (pLow → pHigh) range via setMinAndMax before
//           every run("RGB Color"), making all images directly comparable.
//
// This approach pools pixel histograms (not raw pixel arrays) so it works
// efficiently even across hundreds of large images.

// ── Channel colour slots ──────────────────────────────────────────────────────
// c1=red  c2=green  c3=blue  c4=grey  c5=cyan  c6=magenta  c7=yellow
MERGE_SLOT_C1 = "c2";   // GFP         → green
MERGE_SLOT_C2 = "c1";   // CY5         → red
MERGE_SLOT_C3 = "c4";   // Brightfield → grey

// Composite channel index derived from slot string ("c2" → 2)
mergeChC1 = parseInt(substring(MERGE_SLOT_C1, 1));
mergeChC2 = parseInt(substring(MERGE_SLOT_C2, 1));
mergeChC3 = parseInt(substring(MERGE_SLOT_C3, 1));

// ── Percentile stretch settings ───────────────────────────────────────────────
// Pooled across ALL series in the folder; same range applied to every image.
P_LOW  = 1.0;    // lower percentile (%) — clips dark noise / background
P_HIGH = 99.0;   // upper percentile (%) — clips bright outlier pixels

// Histogram: 4096 bins over 0-65535  ->  16 intensity units per bin.
// Memory cost: 3 channels x 4096 x 8 bytes = 96 KB regardless of dataset size.
N_BINS     = 4096;
HIST_MAX   = 65535;
SAT_THRESH = 65000;   // pixels >= this value are counted as saturated in the report

// ── Override section — paste computed values here to lock a stretch ───────────
// Leave at -1 to auto-detect from this batch.
// To reuse a previously computed stretch, copy Intensity_Low/High from
// normalisation_ranges.csv and paste the values below (raw intensity units).
//
//   Example (copy from CSV, then replace -1 with actual value):
//   FIXED_LOW_C1 = 134;    FIXED_HIGH_C1 = 47280;
//   FIXED_LOW_C2 = 89;     FIXED_HIGH_C2 = 61047;
//   FIXED_LOW_C3 = 201;    FIXED_HIGH_C3 = 65535;
//
FIXED_LOW_C1  = -1;   FIXED_HIGH_C1 = -1;
FIXED_LOW_C2  = -1;   FIXED_HIGH_C2 = -1;
FIXED_LOW_C3  = -1;   FIXED_HIGH_C3 = -1;

// ── Scale bar settings ────────────────────────────────────────────────────────
// Burned into every RGB image before saving (channels, merged).
// Montage and spot-marked images inherit it automatically (re-open saved files).
SB_UM       = 100;            // physical length in µm
SB_HEIGHT   = 8;              // bar thickness in pixels
SB_FONT     = 18;             // label font size
SB_COLOR    = "White";        // "White", "Black", "Yellow" …
SB_LOCATION = "Lower Right";  // "Lower Right", "Lower Left", "Upper Right", "Upper Left"
SB_BOLD     = true;           // bold label text

// ── Montage settings ──────────────────────────────────────────────────────────
BORDER_PX  = 10;
LABEL_SIZE = 24;

// ── Spot measurement settings ─────────────────────────────────────────────────
SPOT_SIZE_FRAC = 0.08;
spotXfrac = newArray(0.15, 0.85, 0.50, 0.15, 0.85);
spotYfrac = newArray(0.15, 0.15, 0.50, 0.85, 0.85);
spotNames = newArray("TL", "TR", "C", "BL", "BR");
SPOT_LW   = 3;
SPOT_FONT = 20;
SPOT_R = 255;  SPOT_G = 255;  SPOT_B = 0;

// ── Pick input folder ─────────────────────────────────────────────────────────
inputDir = getDirectory("Select folder containing ND2 files");
if (inputDir == "") exit("No folder selected — aborted.");

outputDir  = inputDir + "processed"       + File.separator;
rawDir     = outputDir + "1_RAW_TIF"      + File.separator;
splitDir   = outputDir + "2_channels"     + File.separator;
mergeDir   = outputDir + "3_merged"       + File.separator;
montageDir = outputDir + "4_montage"      + File.separator;
measDir    = outputDir + "5_measurements" + File.separator;
spotDir    = outputDir + "6_spot_marked"  + File.separator;

allDirs = newArray(outputDir, rawDir, splitDir, mergeDir, montageDir, measDir, spotDir);
for (d = 0; d < allDirs.length; d++)
    if (!File.exists(allDirs[d])) File.makeDirectory(allDirs[d]);

// ── Initialise CSV content strings ────────────────────────────────────────────
csvPath     = measDir + "fluorescence_measurements.csv";
summaryPath = measDir + "mean_intensity_summary.csv";
spotPath    = measDir + "spot_measurements.csv";
normPath    = measDir + "normalisation_ranges.csv";

csvContent     = "ND2_File,Series_ID,Channel,Mean_Intensity,Min,Max,StdDev,Area_px\n";
summaryContent = "ND2_File,Series_ID,GFP_mean_intensity,CY5_mean_intensity\n";
spotContent    = "ND2_File,Series_ID,Spot_No,Position,X_px,Y_px,Size_px,GFP_mean,CY5_mean\n";

// ── Collect ND2 files ─────────────────────────────────────────────────────────
list = getFileList(inputDir);
nd2List = newArray(0);
for (i = 0; i < list.length; i++)
    if (endsWith(toLowerCase(list[i]), ".nd2"))
        nd2List = Array.concat(nd2List, list[i]);

if (nd2List.length == 0) exit("No ND2 files found in:\n" + inputDir);

print("\\Clear");
print("=== Batch ND2 Processor — global percentile normalisation ===");
print("Input : " + inputDir);
print("Files : " + nd2List.length);
print("Stretch: p" + P_LOW + " – p" + P_HIGH + "  (" + N_BINS + " histogram bins)");

// ════════════════════════════════════════════════════════════════════════════
// PASS 1 — pool histograms across all series to find global percentile range
// ════════════════════════════════════════════════════════════════════════════
print("\n--- PASS 1: pooling histograms ---");

// One accumulated histogram per channel (indices 0=C1, 1=C2, 2=C3)
histC1 = newArray(N_BINS);
histC2 = newArray(N_BINS);
histC3 = newArray(N_BINS);

setBatchMode(true);

for (f = 0; f < nd2List.length; f++) {
    fileName = nd2List[f];
    filePath = inputDir + fileName;
    print("[" + (f+1) + "/" + nd2List.length + "] " + fileName);

    run("Bio-Formats Macro Extensions");
    Ext.setId(filePath);
    Ext.getSeriesCount(nSeries);

    for (s = 0; s < nSeries; s++) {
        run("Bio-Formats Importer",
            "open=[" + filePath + "] " +
            "color_mode=Default autoscale view=Hyperstack " +
            "stack_order=XYCZT open_all_series=false series_" + (s + 1));

        rawTitle = getTitle();
        getDimensions(imgW, imgH, nCh, nZ, nT);

        // Apply the same MAX projection that Pass 2 will use
        if (nZ > 1) {
            run("Z Project...", "projection=[Max Intensity] all");
            maxTitle = getTitle();
            selectWindow(rawTitle); close();
        } else {
            maxTitle = rawTitle;
        }

        nScan = minOf(nCh, 3);
        for (c = 1; c <= nScan; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=hist_ch duplicate channels=" + c);

            // Collect histogram over full 16-bit range with fixed N_BINS
            getHistogram(hVals, hCounts, N_BINS, 0, HIST_MAX);

            // Accumulate into the per-channel pooled histogram
            if (c == 1) { for (b = 0; b < N_BINS; b++) histC1[b] += hCounts[b]; }
            if (c == 2) { for (b = 0; b < N_BINS; b++) histC2[b] += hCounts[b]; }
            if (c == 3) { for (b = 0; b < N_BINS; b++) histC3[b] += hCounts[b]; }
            close();
        }
        selectWindow(maxTitle); close();
    }
    Ext.close();
}

// ════════════════════════════════════════════════════════════════════════════
// COMPUTE PERCENTILES from pooled histograms
// Strategy: walk the cumulative histogram once for pLow, once for pHigh.
//   binW  = width of each bin in intensity units (16.0 for 4096 bins / 65536)
//   pLowCx  = intensity at the P_LOW  percentile of the pooled distribution
//   pHighCx = intensity at the P_HIGH percentile of the pooled distribution
// Result is a pair (pLow[c], pHigh[c]) per channel — the fixed stretch applied
// identically to every image in Pass 2.
// ════════════════════════════════════════════════════════════════════════════
binW   = (HIST_MAX + 1.0) / N_BINS;   // 16.0 for 4096 bins over 0-65535
satBin = floor(SAT_THRESH / binW);    // first bin whose range includes SAT_THRESH

// ── C1: GFP ──────────────────────────────────────────────────────────────────
totalC1 = 0;
for (b = 0; b < N_BINS; b++) totalC1 += histC1[b];
tLow = P_LOW / 100.0 * totalC1;   tHigh = P_HIGH / 100.0 * totalC1;
cumsum = 0;  pLowC1 = 0;
for (b = 0; b < N_BINS; b++) { cumsum += histC1[b]; if (cumsum >= tLow)  { pLowC1  = round(b * binW); b = N_BINS; } }
cumsum = 0;  pHighC1 = HIST_MAX;
for (b = 0; b < N_BINS; b++) { cumsum += histC1[b]; if (cumsum >= tHigh) { pHighC1 = round(b * binW); b = N_BINS; } }
satC1 = 0;
for (b = satBin; b < N_BINS; b++) satC1 += histC1[b];

// ── C2: CY5 ──────────────────────────────────────────────────────────────────
totalC2 = 0;
for (b = 0; b < N_BINS; b++) totalC2 += histC2[b];
tLow = P_LOW / 100.0 * totalC2;   tHigh = P_HIGH / 100.0 * totalC2;
cumsum = 0;  pLowC2 = 0;
for (b = 0; b < N_BINS; b++) { cumsum += histC2[b]; if (cumsum >= tLow)  { pLowC2  = round(b * binW); b = N_BINS; } }
cumsum = 0;  pHighC2 = HIST_MAX;
for (b = 0; b < N_BINS; b++) { cumsum += histC2[b]; if (cumsum >= tHigh) { pHighC2 = round(b * binW); b = N_BINS; } }
satC2 = 0;
for (b = satBin; b < N_BINS; b++) satC2 += histC2[b];

// ── C3: Brightfield ──────────────────────────────────────────────────────────
totalC3 = 0;
for (b = 0; b < N_BINS; b++) totalC3 += histC3[b];
tLow = P_LOW / 100.0 * totalC3;   tHigh = P_HIGH / 100.0 * totalC3;
cumsum = 0;  pLowC3 = 0;
for (b = 0; b < N_BINS; b++) { cumsum += histC3[b]; if (cumsum >= tLow)  { pLowC3  = round(b * binW); b = N_BINS; } }
cumsum = 0;  pHighC3 = HIST_MAX;
for (b = 0; b < N_BINS; b++) { cumsum += histC3[b]; if (cumsum >= tHigh) { pHighC3 = round(b * binW); b = N_BINS; } }
satC3 = 0;
for (b = satBin; b < N_BINS; b++) satC3 += histC3[b];

// ── Apply manual overrides where provided ────────────────────────────────────
if (FIXED_LOW_C1  >= 0) pLowC1  = FIXED_LOW_C1;
if (FIXED_HIGH_C1 >= 0) pHighC1 = FIXED_HIGH_C1;
if (FIXED_LOW_C2  >= 0) pLowC2  = FIXED_LOW_C2;
if (FIXED_HIGH_C2 >= 0) pHighC2 = FIXED_HIGH_C2;
if (FIXED_LOW_C3  >= 0) pLowC3  = FIXED_LOW_C3;
if (FIXED_HIGH_C3 >= 0) pHighC3 = FIXED_HIGH_C3;

// ── Bundle into 0-based arrays: index 0=C1, 1=C2, 2=C3 ──────────────────────
// These are the (min, max) pairs applied channel-by-channel in Pass 2.
pLow  = newArray(pLowC1,  pLowC2,  pLowC3);
pHigh = newArray(pHighC1, pHighC2, pHighC3);

// ── Print summary table (tab-separated for reliable Log window alignment) ─────
satPctC1 = satC1 * 100.0 / maxOf(totalC1, 1);
satPctC2 = satC2 * 100.0 / maxOf(totalC2, 1);
satPctC3 = satC3 * 100.0 / maxOf(totalC3, 1);

print("\n=== Normalisation ranges (pooled " + nd2List.length + " file(s), "
      + "p" + P_LOW + " - p" + P_HIGH + ") ===");
print("Channel\tLabel\tp_Low%\tp_High%\tMin\tMax\tSat%>=65000");
print("-------\t-----\t------\t-------\t---\t---\t-----------");
print("C1\tGFP\t"          + d2s(P_LOW,1) + "\t" + d2s(P_HIGH,1) + "\t" + pLowC1 + "\t" + pHighC1 + "\t" + d2s(satPctC1,3) + "%");
print("C2\tCY5\t"          + d2s(P_LOW,1) + "\t" + d2s(P_HIGH,1) + "\t" + pLowC2 + "\t" + pHighC2 + "\t" + d2s(satPctC2,3) + "%");
print("C3\tBrightfield\t"  + d2s(P_LOW,1) + "\t" + d2s(P_HIGH,1) + "\t" + pLowC3 + "\t" + pHighC3 + "\t" + d2s(satPctC3,3) + "%");
print("-------\t-----\t------\t-------\t---\t---\t-----------");
print("To lock this stretch for future batches, paste into the override section:");
print("  FIXED_LOW_C1 = " + pLowC1 + ";   FIXED_HIGH_C1 = " + pHighC1 + ";");
print("  FIXED_LOW_C2 = " + pLowC2 + ";   FIXED_HIGH_C2 = " + pHighC2 + ";");
print("  FIXED_LOW_C3 = " + pLowC3 + ";   FIXED_HIGH_C3 = " + pHighC3 + ";");

// ── Save normalisation_ranges.csv ─────────────────────────────────────────────
normContent =
    "Channel,Label,p_Low(%),p_High(%),Intensity_Low,Intensity_High,Total_Pixels\n" +
    "C1,GFP,"         + P_LOW + "," + P_HIGH + "," + pLowC1 + "," + pHighC1 + "," + totalC1 + "\n" +
    "C2,CY5,"         + P_LOW + "," + P_HIGH + "," + pLowC2 + "," + pHighC2 + "," + totalC2 + "\n" +
    "C3,Brightfield," + P_LOW + "," + P_HIGH + "," + pLowC3 + "," + pHighC3 + "," + totalC3 + "\n";
File.saveString(normContent, normPath);

// ════════════════════════════════════════════════════════════════════════════
// PASS 2 — process every series applying the fixed percentile stretch
// ════════════════════════════════════════════════════════════════════════════
print("\n--- PASS 2: processing with fixed percentile stretch ---");

for (f = 0; f < nd2List.length; f++) {
    fileName = nd2List[f];
    base     = substring(fileName, 0, lastIndexOf(fileName, "."));
    filePath = inputDir + fileName;
    print("[" + (f+1) + "/" + nd2List.length + "] " + fileName);

    run("Bio-Formats Macro Extensions");
    Ext.setId(filePath);
    Ext.getSeriesCount(nSeries);

    for (s = 0; s < nSeries; s++) {

        if ((s + 1) < 10) seriesLabel = "0" + (s + 1);
        else               seriesLabel = "" + (s + 1);
        seriesBase = base + "_s" + seriesLabel;

        run("Bio-Formats Importer",
            "open=[" + filePath + "] " +
            "color_mode=Default autoscale view=Hyperstack " +
            "stack_order=XYCZT open_all_series=false series_" + (s + 1));

        rawTitle = getTitle();
        getDimensions(imgW, imgH, nCh, nZ, nT);
        getVoxelSize(vw, vh, vd, vunit);
        print("  s" + seriesLabel + ": " + imgW + "x" + imgH +
              "  C=" + nCh + "  Z=" + nZ + "  pixel=" + vw + " " + vunit);

        // ── 1. MAX projection → save raw TIF ──────────────────────────────────
        selectWindow(rawTitle);
        if (nZ > 1) {
            run("Z Project...", "projection=[Max Intensity] all");
            maxTitle = getTitle();
            selectWindow(rawTitle); close();
        } else {
            maxTitle = rawTitle;
        }
        selectWindow(maxTitle);
        saveAs("Tiff", rawDir + seriesBase + "_MAX.tif");
        maxTitle = getTitle();

        // ── 5. Whole-image measurements (raw 16-bit, no stretch applied) ──────
        chLabels = newArray("GFP_C1", "CY5_C2");
        gfpMean = 0;  cy5Mean = 0;
        for (c = 1; c <= 2; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=meas_ch duplicate channels=" + c);
            getStatistics(areaPx, meanVal, minVal, maxVal, stdVal);
            csvContent = csvContent +
                         fileName + "," + seriesBase + "," + chLabels[c-1] + "," +
                         meanVal  + "," + minVal + "," + maxVal + "," + stdVal + "," + areaPx + "\n";
            if (c == 1) gfpMean = meanVal;
            else        cy5Mean = meanVal;
            close();
        }
        summaryContent = summaryContent +
                         fileName + "," + seriesBase + "," + gfpMean + "," + cy5Mean + "\n";

        // ── 6a. Spot measurements (raw 16-bit) ────────────────────────────────
        spotSize = round(imgW * SPOT_SIZE_FRAC);
        spX = newArray(5);  spY = newArray(5);
        for (sp = 0; sp < 5; sp++) {
            spX[sp] = maxOf(0, minOf(round(spotXfrac[sp]*imgW - spotSize/2), imgW - spotSize));
            spY[sp] = maxOf(0, minOf(round(spotYfrac[sp]*imgH - spotSize/2), imgH - spotSize));
            makeRectangle(spX[sp], spY[sp], spotSize, spotSize);
            selectWindow(maxTitle);
            Stack.setChannel(1);  getStatistics(spArea, spGFP);
            selectWindow(maxTitle);
            Stack.setChannel(2);  getStatistics(spArea, spCY5);
            spotContent = spotContent +
                          fileName + "," + seriesBase + "," + (sp+1) + "," +
                          spotNames[sp] + "," + spX[sp] + "," + spY[sp] + "," +
                          spotSize + "," + spGFP + "," + spCY5 + "\n";
        }
        run("Select None");

        // ── Build scale bar command string once per series ────────────────────
        sbCmd = "width=" + SB_UM + " height=" + SB_HEIGHT + " font=" + SB_FONT +
                " color=" + SB_COLOR + " background=None" +
                " location=[" + SB_LOCATION + "]";
        if (SB_BOLD) sbCmd = sbCmd + " bold";

        // ── 2. Split channels → percentile-stretched RGB + scale bar ──────────
        chTags  = newArray("C1_GFP", "C2_CY5", "C3_BF");
        chSlots = newArray(MERGE_SLOT_C1, MERGE_SLOT_C2, MERGE_SLOT_C3);
        nSave   = minOf(nCh, 3);

        for (c = 1; c <= nSave; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=split_tmp duplicate channels=" + c);
            run("Merge Channels...", chSlots[c-1] + "=split_tmp create");
            setMinAndMax(pLow[c-1], pHigh[c-1]);
            run("RGB Color");
            run("Scale Bar...", sbCmd);
            saveAs("Tiff", splitDir + seriesBase + "_" + chTags[c-1] + ".tif");
            close();
        }

        // ── 3. Merge C1 + C2 → percentile-stretched RGB + scale bar ───────────
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C1 duplicate channels=1");
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C2 duplicate channels=2");

        run("Merge Channels...",
            MERGE_SLOT_C1 + "=forMerge_C1 " +
            MERGE_SLOT_C2 + "=forMerge_C2 " +
            "create");

        Stack.setChannel(mergeChC1);
        setMinAndMax(pLow[0], pHigh[0]);
        Stack.setChannel(mergeChC2);
        setMinAndMax(pLow[1], pHigh[1]);
        run("RGB Color");
        run("Scale Bar...", sbCmd);
        saveAs("Tiff", mergeDir + seriesBase + "_merged_C1C2.tif");
        close();

        // ── 6b. Spot-marked image (drawn on normalised merged RGB) ─────────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif");
        markedTitle = getTitle();
        setColor(SPOT_R, SPOT_G, SPOT_B);
        setLineWidth(SPOT_LW);
        setFont("SansSerif", SPOT_FONT, "bold antialiased");
        for (sp = 0; sp < 5; sp++) {
            drawRect(spX[sp], spY[sp], spotSize, spotSize);
            labelY = spY[sp] - 4;
            if (labelY < SPOT_FONT) labelY = spY[sp] + SPOT_FONT + 4;
            drawString("S" + (sp+1) + " " + spotNames[sp], spX[sp] + 2, labelY);
        }
        run("Select None");
        saveAs("Tiff", spotDir + seriesBase + "_spots_marked.tif");
        close();

        // ── 4. Montage: merged / C1 GFP / C2 CY5 ─────────────────────────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif"); panelMerge = getTitle();
        open(splitDir + seriesBase + "_C1_GFP.tif");      panelC1    = getTitle();
        open(splitDir + seriesBase + "_C2_CY5.tif");      panelC2    = getTitle();

        if (LABEL_SIZE > 0) {
            labels = newArray("Merged (GFP+CY5)", "C1  GFP", "C2  CY5");
            panels = newArray(panelMerge, panelC1, panelC2);
            setFont("SansSerif", LABEL_SIZE, "bold antialiased");
            setColor(255, 255, 255);
            for (p = 0; p < panels.length; p++) {
                selectWindow(panels[p]);
                drawString(labels[p], BORDER_PX, LABEL_SIZE + BORDER_PX);
            }
        }
        run("Images to Stack", "name=montage_stack title=[] use");
        run("Make Montage...",
            "columns=1 rows=3 scale=1 border=" + BORDER_PX + " font=0 use");
        saveAs("Tiff", montageDir + seriesBase + "_montage.tif");
        close();
        if (isOpen("montage_stack")) { selectWindow("montage_stack"); close(); }

        // ── Cleanup ───────────────────────────────────────────────────────────
        if (isOpen(maxTitle)) { selectWindow(maxTitle); close(); }
        print("    s" + seriesLabel + " done.");
    }

    Ext.close();
    print("  -> " + outputDir);
}

setBatchMode(false);

// ── Write all CSVs ────────────────────────────────────────────────────────────
File.saveString(csvContent,     csvPath);
File.saveString(summaryContent, summaryPath);
File.saveString(spotContent,    spotPath);

print("\n--- All done ---");
print("Normalisation  : " + normPath);
print("Detail CSV     : " + csvPath);
print("Summary CSV    : " + summaryPath);
print("Spot CSV       : " + spotPath);
print("Output folder  : " + outputDir);
