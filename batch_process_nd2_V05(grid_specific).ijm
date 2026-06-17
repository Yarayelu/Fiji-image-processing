// Batch ND2 Processor V05 — Multi-series + Segmentation-based GFP Measurement
//
// Image-processing pipeline (unchanged from V04):
//   1. MAX projection, save raw TIF
//   2. Split channels → percentile-stretched RGB + scale bar
//   3. Merge C1 + C2 → percentile-stretched RGB + scale bar
//   4. Montage (Merged / C1 GFP / C2 BF, 1 column)
//
// NEW measurement strategy (replaces V04 fixed-spot approach):
//   C2 (Brightfield) is used for segmentation — its histogram has three peaks:
//     DARK  = grid bars      (metal, blocks light)
//     GRAY  = carbon squares (graphene present, partial transmission)
//     WHITE = broken squares (no graphene, full transmission)
//   Two valley thresholds T1 and T2 are auto-detected from a smoothed histogram.
//
//   Measurement A — whole-image carbon region:
//     Apply [T1, T2] mask on C2, measure C1 (GFP) mean intensity in that region.
//
//   Measurement B — 5 squares × 3 spots each (15 measurements per series):
//     Analyze Particles on the carbon mask to find individual squares.
//     Pick the 5 squares whose centroids are closest to the image centre.
//     Inside each square place 3 small spots (centre, upper-left, lower-right).
//     Measure C1 GFP mean in each spot.
//
// Outputs:
//   5_measurements/normalisation_ranges.csv     — percentile stretch ranges
//   5_measurements/carbon_segmentation.csv      — whole-region GFP per series
//   5_measurements/square_spot_measurements.csv — 15 spot GFP values per series
//   6_class_maps/  — colour map: red=bars, green=carbon, blue=broken
//   7_seg_spots/   — merged RGB: 5 squares (yellow) + 3 spots each (cyan)

// ═══════════════════════════════════════════════════════════════════════════════
// SETTINGS
// ═══════════════════════════════════════════════════════════════════════════════

// ── Channel colour slots ──────────────────────────────────────────────────────
// c1=red  c2=green  c3=blue  c4=grey  c5=cyan  c6=magenta  c7=yellow
MERGE_SLOT_C1 = "c2";   // GFP         → green
MERGE_SLOT_C2 = "c4";   // Brightfield → grey  (shown in merged for context)

// Composite channel index derived from slot string ("c2" → 2)
mergeChC1 = parseInt(substring(MERGE_SLOT_C1, 1));
mergeChC2 = parseInt(substring(MERGE_SLOT_C2, 1));

// ── Percentile stretch settings ───────────────────────────────────────────────
P_LOW  = 1.0;
P_HIGH = 99.0;
N_BINS     = 4096;
HIST_MAX   = 65535;
SAT_THRESH = 65000;

// Override: -1 = auto-detect; paste values from normalisation_ranges.csv to lock.
FIXED_LOW_C1  = -1;   FIXED_HIGH_C1 = -1;
FIXED_LOW_C2  = -1;   FIXED_HIGH_C2 = -1;

// ── Scale bar settings ────────────────────────────────────────────────────────
SB_UM       = 100;
SB_HEIGHT   = 8;
SB_FONT     = 18;
SB_COLOR    = "White";
SB_LOCATION = "Lower Right";
SB_BOLD     = true;

// ── Montage settings ──────────────────────────────────────────────────────────
BORDER_PX  = 10;
LABEL_SIZE = 24;

// ── Segmentation settings (C2 brightfield → 3-class thresholding) ─────────────
SEG_CHANNEL   = 2;     // channel number used for segmentation (1-based)
SEG_SMOOTH_PASSES = 3; // iterations of 5-point histogram smoothing

// Valley search ranges — fractions of the per-image intensity span (0.0–1.0):
//   T1 separates DARK bars   from GRAY carbon squares
//   T2 separates GRAY carbon from WHITE broken squares
T1_SEARCH_MIN = 0.05;
T1_SEARCH_MAX = 0.45;
T2_SEARCH_MIN = 0.55;
T2_SEARCH_MAX = 0.95;

// Manual threshold override: -1 = auto-detect; set raw intensity value to lock.
// If the class map looks wrong, read T1/T2 from carbon_segmentation.csv and
// paste corrected values here.
MANUAL_T1 = -1;
MANUAL_T2 = -1;

// ── Square detection settings ─────────────────────────────────────────────────
// Area bounds for individual carbon square detection (fraction of image area).
// Squares outside this range are ignored (noise or merged regions).
MIN_SQUARE_AREA_FRAC = 0.0001;   // lower = accepts smaller squares; raise if noise is detected
MAX_SQUARE_AREA_FRAC = 0.20;    // upper = rejects merged/broken regions

// N_SEL_SQUARES: how many carbon squares to select (ranked by proximity to
// the image centre — well-focused central region).
// For each selected square:
//   • whole-square measurement: mean C1 GFP over the exact carbon ROI
//   • 2 spot measurements: mean C2 (BF) over the carbon pixels inside each spot
// N_SPOTS_PER_SQ spots are placed at sqSpotXfrac / sqSpotYfrac positions
// within the bounding box.  SQ_SPOT_SIZE_FRAC controls the spot side length
// as a fraction of the square's shorter dimension.
N_SEL_SQUARES    = 5;
N_SPOTS_PER_SQ   = 2;
SQ_SPOT_SIZE_FRAC = 0.20;
sqSpotXfrac = newArray(0.30, 0.70);   // left-centre, right-centre
sqSpotYfrac = newArray(0.50, 0.50);

// ═══════════════════════════════════════════════════════════════════════════════
// DIRECTORY SETUP
// ═══════════════════════════════════════════════════════════════════════════════
inputDir = getDirectory("Select folder containing ND2 files");
if (inputDir == "") exit("No folder selected — aborted.");

outputDir  = inputDir + "processed"       + File.separator;
rawDir     = outputDir + "1_RAW_TIF"      + File.separator;
splitDir   = outputDir + "2_channels"     + File.separator;
mergeDir   = outputDir + "3_merged"       + File.separator;
montageDir = outputDir + "4_montage"      + File.separator;
measDir    = outputDir + "5_measurements" + File.separator;
classDir   = outputDir + "6_class_maps"   + File.separator;
segSpotDir = outputDir + "7_seg_spots"    + File.separator;

allDirs = newArray(outputDir, rawDir, splitDir, mergeDir, montageDir,
                   measDir, classDir, segSpotDir);
for (d = 0; d < allDirs.length; d++)
    if (!File.exists(allDirs[d])) File.makeDirectory(allDirs[d]);

// ── CSV paths & headers ───────────────────────────────────────────────────────
normPath    = measDir + "normalisation_ranges.csv";
carbonPath  = measDir + "carbon_segmentation.csv";
sqSpotPath  = measDir + "square_gfp_measurements.csv";
spotC2Path  = measDir + "square_spot_c2_measurements.csv";

carbonContent =
    "ND2_File,Series_ID,Auto_T1,Auto_T2,Used_T1,Used_T2," +
    "Carbon_GFP_Mean,Carbon_GFP_StdDev,Carbon_Area_px,Carbon_Fraction%\n";

// 5 rows per series — whole-square C1 GFP over the exact carbon ROI
sqSpotContent =
    "ND2_File,Series_ID,Square_No,Square_X,Square_Y,Square_W,Square_H," +
    "Carbon_Area_px,C1_GFP_Mean\n";

// 10 rows per series — C2 mean within carbon pixels of each spot (2 per square)
spotC2Content =
    "ND2_File,Series_ID,Square_No,Spot_No,Spot_X,Spot_Y,Spot_Size_px," +
    "C2_Carbon_Mean\n";

// ── Collect ND2 files ─────────────────────────────────────────────────────────
list = getFileList(inputDir);
nd2List = newArray(0);
for (i = 0; i < list.length; i++)
    if (endsWith(toLowerCase(list[i]), ".nd2"))
        nd2List = Array.concat(nd2List, list[i]);

if (nd2List.length == 0) exit("No ND2 files found in:\n" + inputDir);

print("\\Clear");
print("=== Batch ND2 Processor V05 ===");
print("Input : " + inputDir);
print("Files : " + nd2List.length);
print("Stretch: p" + P_LOW + " - p" + P_HIGH + "  (" + N_BINS + " bins)");
print("Seg channel: C" + SEG_CHANNEL + "  T1 search [" +
      T1_SEARCH_MIN + "," + T1_SEARCH_MAX + "]  T2 search [" +
      T2_SEARCH_MIN + "," + T2_SEARCH_MAX + "]");

// ═══════════════════════════════════════════════════════════════════════════════
// PASS 1 — pool histograms across all series for global percentile stretch
// ═══════════════════════════════════════════════════════════════════════════════
print("\n--- PASS 1: pooling histograms for normalisation ---");

histC1 = newArray(N_BINS);
histC2 = newArray(N_BINS);

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
            "stack_order=XYCZT open_all_series=false series_" + (s+1));

        rawTitle = getTitle();
        getDimensions(imgW, imgH, nCh, nZ, nT);

        if (nZ > 1) {
            run("Z Project...", "projection=[Max Intensity] all");
            maxTitle = getTitle();
            selectWindow(rawTitle); close();
        } else {
            maxTitle = rawTitle;
        }

        nScan = minOf(nCh, 2);   // only C1 and C2 need normalisation
        for (c = 1; c <= nScan; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=hist_ch duplicate channels=" + c);
            getHistogram(hVals, hCounts, N_BINS, 0, HIST_MAX);
            if (c == 1) { for (b = 0; b < N_BINS; b++) histC1[b] += hCounts[b]; }
            if (c == 2) { for (b = 0; b < N_BINS; b++) histC2[b] += hCounts[b]; }
            close();
        }
        selectWindow(maxTitle); close();
    }
    Ext.close();
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMPUTE PERCENTILES from pooled histograms
// ═══════════════════════════════════════════════════════════════════════════════
binW   = (HIST_MAX + 1.0) / N_BINS;
satBin = floor(SAT_THRESH / binW);

// C1: GFP
totalC1 = 0;
for (b = 0; b < N_BINS; b++) totalC1 += histC1[b];
tLow = P_LOW / 100.0 * totalC1;   tHigh = P_HIGH / 100.0 * totalC1;
cumsum = 0;  pLowC1 = 0;
for (b = 0; b < N_BINS; b++) { cumsum += histC1[b]; if (cumsum >= tLow)  { pLowC1  = round(b*binW); b = N_BINS; } }
cumsum = 0;  pHighC1 = HIST_MAX;
for (b = 0; b < N_BINS; b++) { cumsum += histC1[b]; if (cumsum >= tHigh) { pHighC1 = round(b*binW); b = N_BINS; } }
satC1 = 0;
for (b = satBin; b < N_BINS; b++) satC1 += histC1[b];

// C2: Brightfield
totalC2 = 0;
for (b = 0; b < N_BINS; b++) totalC2 += histC2[b];
tLow = P_LOW / 100.0 * totalC2;   tHigh = P_HIGH / 100.0 * totalC2;
cumsum = 0;  pLowC2 = 0;
for (b = 0; b < N_BINS; b++) { cumsum += histC2[b]; if (cumsum >= tLow)  { pLowC2  = round(b*binW); b = N_BINS; } }
cumsum = 0;  pHighC2 = HIST_MAX;
for (b = 0; b < N_BINS; b++) { cumsum += histC2[b]; if (cumsum >= tHigh) { pHighC2 = round(b*binW); b = N_BINS; } }
satC2 = 0;
for (b = satBin; b < N_BINS; b++) satC2 += histC2[b];

// Apply manual overrides
if (FIXED_LOW_C1  >= 0) pLowC1  = FIXED_LOW_C1;
if (FIXED_HIGH_C1 >= 0) pHighC1 = FIXED_HIGH_C1;
if (FIXED_LOW_C2  >= 0) pLowC2  = FIXED_LOW_C2;
if (FIXED_HIGH_C2 >= 0) pHighC2 = FIXED_HIGH_C2;

pLow  = newArray(pLowC1,  pLowC2);
pHigh = newArray(pHighC1, pHighC2);

satPctC1 = satC1 * 100.0 / maxOf(totalC1, 1);
satPctC2 = satC2 * 100.0 / maxOf(totalC2, 1);

print("\n=== Normalisation ranges (p" + P_LOW + " - p" + P_HIGH + ") ===");
print("Channel\tLabel\tMin\tMax\tSat%>=65000");
print("C1\tGFP\t"          + pLowC1 + "\t" + pHighC1 + "\t" + d2s(satPctC1,3) + "%");
print("C2\tBrightfield\t"  + pLowC2 + "\t" + pHighC2 + "\t" + d2s(satPctC2,3) + "%");
print("To lock: FIXED_LOW_C1=" + pLowC1 + ";  FIXED_HIGH_C1=" + pHighC1 + ";");
print("         FIXED_LOW_C2=" + pLowC2 + ";  FIXED_HIGH_C2=" + pHighC2 + ";");

normContent =
    "Channel,Label,p_Low(%),p_High(%),Intensity_Low,Intensity_High,Total_Pixels\n" +
    "C1,GFP,"         + P_LOW + "," + P_HIGH + "," + pLowC1 + "," + pHighC1 + "," + totalC1 + "\n" +
    "C2,Brightfield," + P_LOW + "," + P_HIGH + "," + pLowC2 + "," + pHighC2 + "," + totalC2 + "\n";
File.saveString(normContent, normPath);

// ═══════════════════════════════════════════════════════════════════════════════
// PASS 2 — process every series with fixed stretch + segmentation measurements
// ═══════════════════════════════════════════════════════════════════════════════
print("\n--- PASS 2: processing ---");

for (f = 0; f < nd2List.length; f++) {
    fileName = nd2List[f];
    base     = substring(fileName, 0, lastIndexOf(fileName, "."));
    filePath = inputDir + fileName;
    print("[" + (f+1) + "/" + nd2List.length + "] " + fileName);

    run("Bio-Formats Macro Extensions");
    Ext.setId(filePath);
    Ext.getSeriesCount(nSeries);

    for (s = 0; s < nSeries; s++) {

        if ((s+1) < 10) seriesLabel = "0" + (s+1);
        else             seriesLabel = "" + (s+1);
        seriesBase = base + "_s" + seriesLabel;

        run("Bio-Formats Importer",
            "open=[" + filePath + "] " +
            "color_mode=Default autoscale view=Hyperstack " +
            "stack_order=XYCZT open_all_series=false series_" + (s+1));

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

        totalPx = imgW * imgH;

        // ══════════════════════════════════════════════════════════════════════
        // SEGMENTATION — auto-detect T1 & T2 from C2 (brightfield) histogram
        // ══════════════════════════════════════════════════════════════════════

        // Extract brightfield channel for segmentation
        selectWindow(maxTitle);
        run("Duplicate...", "title=bf_seg duplicate channels=" + SEG_CHANNEL);
        bfSeg = getTitle();

        // 256-bin histogram over the actual intensity range of this image
        getStatistics(stArea, stMean, stMin, stMax);
        if (stMax <= stMin) stMax = stMin + 1;
        getHistogram(hVals, hSeg, 256, stMin, stMax);
        binW_real = (stMax - stMin) / 255.0;

        // Smooth histogram (SEG_SMOOTH_PASSES x 5-point moving average)
        hSmooth = newArray(256);
        for (b = 0; b < 256; b++) hSmooth[b] = hSeg[b];
        for (pass = 0; pass < SEG_SMOOTH_PASSES; pass++) {
            hTmp = newArray(256);
            hTmp[0]   = (hSmooth[0]+hSmooth[1]+hSmooth[2]) / 3.0;
            hTmp[1]   = (hSmooth[0]+hSmooth[1]+hSmooth[2]+hSmooth[3]) / 4.0;
            hTmp[254] = (hSmooth[252]+hSmooth[253]+hSmooth[254]+hSmooth[255]) / 4.0;
            hTmp[255] = (hSmooth[253]+hSmooth[254]+hSmooth[255]) / 3.0;
            for (b = 2; b <= 253; b++)
                hTmp[b] = (hSmooth[b-2]+hSmooth[b-1]+hSmooth[b]+hSmooth[b+1]+hSmooth[b+2]) / 5.0;
            for (b = 0; b < 256; b++) hSmooth[b] = hTmp[b];
        }

        // Find the deepest valley in each search window
        t1Lo = round(T1_SEARCH_MIN * 255);   t1Hi = round(T1_SEARCH_MAX * 255);
        t2Lo = round(T2_SEARCH_MIN * 255);   t2Hi = round(T2_SEARCH_MAX * 255);

        t1Bin = t1Lo;   minV1 = hSmooth[t1Lo];
        for (b = t1Lo; b <= t1Hi; b++) if (hSmooth[b] < minV1) { minV1 = hSmooth[b]; t1Bin = b; }

        t2Bin = t2Lo;   minV2 = hSmooth[t2Lo];
        for (b = t2Lo; b <= t2Hi; b++) if (hSmooth[b] < minV2) { minV2 = hSmooth[b]; t2Bin = b; }

        autoT1 = round(stMin + t1Bin * binW_real);
        autoT2 = round(stMin + t2Bin * binW_real);

        if (MANUAL_T1 >= 0) usedT1 = MANUAL_T1; else usedT1 = autoT1;
        if (MANUAL_T2 >= 0) usedT2 = MANUAL_T2; else usedT2 = autoT2;

        if (usedT1 >= usedT2) {
            print("  WARNING s" + seriesLabel + ": T1 >= T2 — using fallback 20/70% thresholds");
            usedT1 = round(stMin + 0.20 * (stMax - stMin));
            usedT2 = round(stMin + 0.70 * (stMax - stMin));
        }
        print("  s" + seriesLabel + "  BF range [" + stMin + "," + stMax + "]" +
              "  T1=" + usedT1 + "  T2=" + usedT2);

        // ── Measurement A: whole-image carbon region → C1 GFP mean ───────────
        // Create selection from carbon region on bfSeg, save to ROI Manager
        roiManager("reset");
        selectWindow(bfSeg);
        setThreshold(usedT1, usedT2);
        run("Create Selection");

        carbonGFPmean = 0;  carbonGFPstd = 0;
        carbonAreaPx  = 0;  carbonFrac   = 0;

        if (selectionType() != -1) {
            roiManager("Add");    // save carbon ROI at index 0
            // Apply the same selection to a C1 duplicate and measure GFP
            selectWindow(maxTitle);
            run("Duplicate...", "title=c1_meas duplicate channels=1");
            roiManager("select", 0);
            getStatistics(carbonAreaPx, carbonGFPmean, cvMin, cvMax, carbonGFPstd);
            run("Select None");
            close();   // c1_meas
            carbonFrac = carbonAreaPx * 100.0 / totalPx;
        } else {
            print("  WARNING s" + seriesLabel + ": no carbon region found by threshold");
        }
        selectWindow(bfSeg);
        resetThreshold();
        roiManager("reset");

        carbonContent = carbonContent +
            fileName + "," + seriesBase + "," +
            autoT1 + "," + autoT2 + "," + usedT1 + "," + usedT2 + "," +
            d2s(carbonGFPmean,2) + "," + d2s(carbonGFPstd,2) + "," +
            carbonAreaPx + "," + d2s(carbonFrac,3) + "\n";

        print("  s" + seriesLabel + "  carbon: GFP mean=" + d2s(carbonGFPmean,1) +
              "  area=" + carbonAreaPx + " px (" + d2s(carbonFrac,1) + "%)");

        // ── Measurement B: 5 squares × (whole-square C1 GFP + 2-spot C2) ─────────
        // Step 1 — build binary carbon mask (255 = carbon)
        selectWindow(bfSeg);
        setThreshold(usedT1, usedT2);
        run("Create Mask");
        carbonMaskTitle = getTitle();

        // Step 2 — build a 32-bit C2 image where non-carbon pixels are NaN.
        // getStatistics on any rectangle of this image automatically excludes NaN,
        // so the mean reflects only true carbon pixels — no ROI intersection needed.
        selectWindow(bfSeg);
        run("Duplicate...", "title=c2_masked duplicate");
        run("32-bit");
        c2MaskedTitle = getTitle();

        selectWindow(carbonMaskTitle);
        setThreshold(0, 127);             // 0 in mask = non-carbon
        run("Create Selection");
        if (selectionType() != -1) {
            selectWindow(c2MaskedTitle);
            run("Restore Selection");
            run("Set...", "value=NaN");
            run("Select None");
        }
        selectWindow(carbonMaskTitle);
        run("Select None");   // CRITICAL: clear the non-carbon selection or Analyze Particles
        resetThreshold();     // runs inside it and finds nothing (all zeros there)

        // Step 3 — Analyze Particles to find individual carbon squares.
        // setThreshold(128,255) is required: resetThreshold() above cleared the
        // mask's threshold, and Analyze Particles on a binary image with no active
        // threshold finds nothing.
        roiManager("reset");
        minSqPx = round(totalPx * MIN_SQUARE_AREA_FRAC);
        maxSqPx = round(totalPx * MAX_SQUARE_AREA_FRAC);
        print("  s" + seriesLabel + "  particle size filter: " + minSqPx + " – " + maxSqPx + " px²" +
              "  (image " + imgW + "x" + imgH + ")");
        selectWindow(carbonMaskTitle);
        setThreshold(128, 255);   // re-arm: select white (carbon) pixels in the binary mask
        run("Analyze Particles...",
            "size=" + minSqPx + "-" + maxSqPx + " show=Nothing add");
        resetThreshold();
        nROIs = roiManager("count");
        print("  s" + seriesLabel + "  particles found: " + nROIs);
        selectWindow(carbonMaskTitle); close();

        // Step 4 — Greedy selection: N_SEL_SQUARES squares closest to image centre
        nSelSq    = minOf(N_SEL_SQUARES, nROIs);
        selSqX    = newArray(nSelSq);   selSqY    = newArray(nSelSq);
        selSqW    = newArray(nSelSq);   selSqH    = newArray(nSelSq);
        selRoiIdx = newArray(nSelSq);

        if (nROIs == 0) {
            print("  WARNING s" + seriesLabel + ": no carbon squares found (adjust MIN_SQUARE_AREA_FRAC?)");
        } else {
            imgCX = imgW / 2.0;   imgCY = imgH / 2.0;
            used  = newArray(nROIs);
            for (q = 0; q < nSelSq; q++) {
                bestROI = 0;   bestDist = 99999999;
                for (r = 0; r < nROIs; r++) {
                    if (used[r] == 1) continue;
                    roiManager("select", r);
                    getSelectionBounds(rx, ry, rw, rh);
                    rCX = rx + rw / 2.0;   rCY = ry + rh / 2.0;
                    d2  = (rCX-imgCX)*(rCX-imgCX) + (rCY-imgCY)*(rCY-imgCY);
                    if (d2 < bestDist) { bestDist = d2; bestROI = r; }
                }
                used[bestROI] = 1;
                selRoiIdx[q]  = bestROI;
                roiManager("select", bestROI);
                getSelectionBounds(tmpX, tmpY, tmpW, tmpH);
                selSqX[q] = tmpX;   selSqY[q] = tmpY;
                selSqW[q] = tmpW;   selSqH[q] = tmpH;
                run("Select None");
            }
            print("  s" + seriesLabel + "  selected " + nSelSq + " squares  (" + nROIs + " candidates)");
        }

        // Step 5 — Whole-square measurement: mean C1 GFP over each square's carbon ROI
        selectWindow(maxTitle);
        Stack.setChannel(1);   // C1 GFP
        for (q = 0; q < nSelSq; q++) {
            roiManager("select", selRoiIdx[q]);
            getStatistics(sqCarbonArea, sqGFPmean);
            sqSpotContent = sqSpotContent +
                fileName + "," + seriesBase + "," +
                (q+1) + "," +
                selSqX[q] + "," + selSqY[q] + "," + selSqW[q] + "," + selSqH[q] + "," +
                sqCarbonArea + "," + d2s(sqGFPmean, 2) + "\n";
            print("  s" + seriesLabel + "  Q" + (q+1) +
                  "  C1 GFP mean=" + d2s(sqGFPmean,1) + "  carbon px=" + sqCarbonArea);
        }
        selectWindow(maxTitle);   run("Select None");
        roiManager("reset");

        // Step 6 — Spot measurements: 2 spots per square, mean C2 on carbon pixels.
        // c2MaskedTitle has NaN on every non-carbon pixel, so a plain rectangle
        // getStatistics gives the carbon-only mean with no extra masking required.
        selectWindow(c2MaskedTitle);
        for (q = 0; q < nSelSq; q++) {
            qW = selSqW[q];   qH = selSqH[q];
            sqSpotSize = round(minOf(qW, qH) * SQ_SPOT_SIZE_FRAC);
            if (sqSpotSize < 3) sqSpotSize = 3;
            for (sp = 0; sp < N_SPOTS_PER_SQ; sp++) {
                px   = round(selSqX[q] + sqSpotXfrac[sp] * qW - sqSpotSize / 2);
                py   = round(selSqY[q] + sqSpotYfrac[sp] * qH - sqSpotSize / 2);
                spPX = maxOf(selSqX[q], minOf(px, selSqX[q] + qW - sqSpotSize));
                spPY = maxOf(selSqY[q], minOf(py, selSqY[q] + qH - sqSpotSize));
                makeRectangle(spPX, spPY, sqSpotSize, sqSpotSize);
                getStatistics(spArea, spC2mean);   // NaN excluded → carbon-only mean
                run("Select None");
                spotC2Content = spotC2Content +
                    fileName + "," + seriesBase + "," +
                    (q+1) + "," + (sp+1) + "," +
                    spPX + "," + spPY + "," + sqSpotSize + "," +
                    d2s(spC2mean, 2) + "\n";
                print("  s" + seriesLabel + "  Q" + (q+1) + " spot" + (sp+1) +
                      "  C2 carbon mean=" + d2s(spC2mean,1));
            }
        }
        selectWindow(c2MaskedTitle); close();

        // ══════════════════════════════════════════════════════════════════════
        // IMAGE OUTPUTS (same pipeline as V04)
        // ══════════════════════════════════════════════════════════════════════

        // Build scale bar command once per series
        sbCmd = "width=" + SB_UM + " height=" + SB_HEIGHT + " font=" + SB_FONT +
                " color=" + SB_COLOR + " background=None location=[" + SB_LOCATION + "]";
        if (SB_BOLD) sbCmd = sbCmd + " bold";

        // ── 2. Split channels → percentile-stretched RGB + scale bar ──────────
        chTags  = newArray("C1_GFP", "C2_BF");
        chSlots = newArray(MERGE_SLOT_C1, MERGE_SLOT_C2);
        nSave   = minOf(nCh, 2);

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

        // ── 3. Merge C1 (GFP, green) + C2 (BF, grey) → RGB + scale bar ───────
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C1 duplicate channels=1");
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C2 duplicate channels=2");

        run("Merge Channels...",
            MERGE_SLOT_C1 + "=forMerge_C1 " +
            MERGE_SLOT_C2 + "=forMerge_C2 " +
            "create");
        Stack.setChannel(mergeChC1);  setMinAndMax(pLow[0], pHigh[0]);
        Stack.setChannel(mergeChC2);  setMinAndMax(pLow[1], pHigh[1]);
        run("RGB Color");
        run("Scale Bar...", sbCmd);
        saveAs("Tiff", mergeDir + seriesBase + "_merged_C1C2.tif");
        close();

        // ── 6. Class map: red=bars | green=carbon | blue=broken ───────────────
        selectWindow(bfSeg);
        setThreshold(stMin, usedT1 - 1);
        run("Create Mask");   rename("mask_bars");

        selectWindow(bfSeg);
        setThreshold(usedT1, usedT2);
        run("Create Mask");   rename("mask_carbon");

        selectWindow(bfSeg);
        setThreshold(usedT2 + 1, HIST_MAX);
        run("Create Mask");   rename("mask_broken");

        run("Merge Channels...", "c1=mask_bars c2=mask_carbon c3=mask_broken create");
        run("RGB Color");

        // Label T1/T2 values and mark all selected squares in white
        setFont("SansSerif", 20, "bold antialiased");
        setColor(255, 255, 0);
        drawString("T1=" + usedT1 + "  T2=" + usedT2, 8, 26);
        setLineWidth(2);
        setColor(255, 255, 255);
        for (q = 0; q < nSelSq; q++)
            drawRect(selSqX[q], selSqY[q], selSqW[q], selSqH[q]);
        saveAs("Tiff", classDir + seriesBase + "_class_map.tif");
        close();

        // bfSeg no longer needed
        selectWindow(bfSeg); close();

        // ── 7. Measurement overlay: squares (yellow) + C2 spots (cyan) ───────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif");

        setFont("SansSerif", 14, "bold antialiased");
        for (q = 0; q < nSelSq; q++) {
            qW = selSqW[q];   qH = selSqH[q];
            sqSpotSize = round(minOf(qW, qH) * SQ_SPOT_SIZE_FRAC);
            if (sqSpotSize < 3) sqSpotSize = 3;

            // Yellow border + square number
            setColor(255, 255, 0);
            setLineWidth(3);
            drawRect(selSqX[q], selSqY[q], qW, qH);
            drawString("Q" + (q+1), selSqX[q] + 3, selSqY[q] + 16);

            // Cyan spot rectangles (C2 measurement positions)
            setColor(0, 255, 255);
            setLineWidth(2);
            for (sp = 0; sp < N_SPOTS_PER_SQ; sp++) {
                px   = round(selSqX[q] + sqSpotXfrac[sp] * qW - sqSpotSize / 2);
                py   = round(selSqY[q] + sqSpotYfrac[sp] * qH - sqSpotSize / 2);
                spPX = maxOf(selSqX[q], minOf(px, selSqX[q] + qW - sqSpotSize));
                spPY = maxOf(selSqY[q], minOf(py, selSqY[q] + qH - sqSpotSize));
                drawRect(spPX, spPY, sqSpotSize, sqSpotSize);
                drawString("S" + (sp+1), spPX + 2, spPY - 2);
            }
        }
        run("Select None");
        saveAs("Tiff", segSpotDir + seriesBase + "_seg_squares.tif");
        close();

        // ── 4. Montage: merged / C1 GFP / C2 BF (1 column) ──────────────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif");  panelMerge = getTitle();
        open(splitDir + seriesBase + "_C1_GFP.tif");       panelC1    = getTitle();
        open(splitDir + seriesBase + "_C2_BF.tif");        panelC2    = getTitle();

        if (LABEL_SIZE > 0) {
            labels = newArray("Merged (GFP+BF)", "C1  GFP", "C2  BF");
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
File.saveString(carbonContent,  carbonPath);
File.saveString(sqSpotContent,  sqSpotPath);
File.saveString(spotC2Content,  spotC2Path);

print("\n--- All done ---");
print("Normalisation CSV    : " + normPath);
print("Carbon region CSV    : " + carbonPath);
print("Square GFP CSV       : " + sqSpotPath);
print("Spot C2 CSV          : " + spotC2Path);
print("Class maps           : " + classDir);
print("Overlay images       : " + segSpotDir);
print("Output folder        : " + outputDir);
