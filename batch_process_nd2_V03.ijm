// Batch ND2 Processor — Multi-series
// For each ND2 in the folder (handles multiple images per file):
//   1. Save every series as a separate TIF (MAX projection if z-stack)
//   2. Split channels → RGB TIFFs  (C1=GFP green | C2=CY5 red | C3=Brightfield grey)
//   3. Merge C1 + C2 → RGB TIFF
//   4. Montage: 1 column — Merged (top) / C1 GFP (middle) / C2 CY5 (bottom)
//   5. Measure whole-image mean fluorescence for C1 and C2 → CSV
//   6. Sample 5 spots, measure local mean fluorescence, save marked images

// ── Channel colour slots ──────────────────────────────────────────────────────
// Fiji Merge Channels slots: c1=red c2=green c3=blue c4=grey c5=cyan c6=magenta c7=yellow
// Used for BOTH individual channel saves AND the merge → colours always match.
MERGE_SLOT_C1 = "c2";  // GFP        → green
MERGE_SLOT_C2 = "c1";  // CY5        → red
MERGE_SLOT_C3 = "c4";  // Brightfield→ grey (saved separately, not in merge)

// ── Montage settings ──────────────────────────────────────────────────────────
BORDER_PX  = 10;   // gap between panels (px)
LABEL_SIZE = 24;   // white label font size (0 = no labels)

// ── Spot measurement settings ─────────────────────────────────────────────────
// 5 spots placed at TL, TR, Centre, BL, BR — positions as fraction of image size
SPOT_SIZE_FRAC = 0.08;   // each spot = 8% of image width (square)
spotXfrac = newArray(0.15, 0.85, 0.50, 0.15, 0.85);
spotYfrac = newArray(0.15, 0.15, 0.50, 0.85, 0.85);
spotNames = newArray("TL", "TR", "C", "BL", "BR");
SPOT_LW   = 3;    // rectangle stroke width (px)
SPOT_FONT = 20;   // spot label font size
// Marker colour: yellow stands out on both green and red channels
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

// ── Initialise CSV content strings (written to disk once at the end) ─────────
csvPath     = measDir + "fluorescence_measurements.csv";
summaryPath = measDir + "mean_intensity_summary.csv";
spotPath    = measDir + "spot_measurements.csv";

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
print("=== Batch ND2 Processor (multi-series) ===");
print("Input : " + inputDir);
print("Files : " + nd2List.length);
print("---");

setBatchMode(true);

// ── Process each ND2 ─────────────────────────────────────────────────────────
for (f = 0; f < nd2List.length; f++) {
    fileName = nd2List[f];
    base     = substring(fileName, 0, lastIndexOf(fileName, "."));
    filePath = inputDir + fileName;

    print("[" + (f+1) + "/" + nd2List.length + "] " + fileName);

    run("Bio-Formats Macro Extensions");
    Ext.setId(filePath);
    Ext.getSeriesCount(nSeries);
    print("  Series found: " + nSeries);

    for (s = 0; s < nSeries; s++) {

        if ((s + 1) < 10) seriesLabel = "0" + (s + 1);
        else               seriesLabel = "" + (s + 1);
        seriesBase = base + "_s" + seriesLabel;

        // ── Open one series ───────────────────────────────────────────────────
        run("Bio-Formats Importer",
            "open=[" + filePath + "] " +
            "color_mode=Default " +
            "autoscale " +
            "view=Hyperstack " +
            "stack_order=XYCZT " +
            "open_all_series=false " +
            "series_" + (s + 1));

        rawTitle = getTitle();
        getDimensions(imgW, imgH, nCh, nZ, nT);
        getVoxelSize(vw, vh, vd, vunit);
        print("  s" + seriesLabel + ": " + imgW + "x" + imgH +
              "  C=" + nCh + "  Z=" + nZ + "  T=" + nT +
              "  pixel=" + vw + " " + vunit);

        // ── 1. MAX projection (if z-stack) then save raw TIF ─────────────────
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

        // ── 5. Whole-image mean intensity (C1 & C2, raw 16-bit) ──────────────
        chLabels = newArray("GFP_C1", "CY5_C2");
        gfpMean  = 0;
        cy5Mean  = 0;
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

        // ── 6a. Spot measurements (5 spots, raw 16-bit hyperstack) ───────────
        spotSize = round(imgW * SPOT_SIZE_FRAC);
        spX = newArray(5);  spY = newArray(5);   // store for drawing later

        for (sp = 0; sp < 5; sp++) {
            // Centre the spot on the target fraction, clamped to image bounds
            spX[sp] = maxOf(0, minOf(round(spotXfrac[sp] * imgW - spotSize / 2),
                                      imgW - spotSize));
            spY[sp] = maxOf(0, minOf(round(spotYfrac[sp] * imgH - spotSize / 2),
                                      imgH - spotSize));

            makeRectangle(spX[sp], spY[sp], spotSize, spotSize);

            selectWindow(maxTitle);
            Stack.setChannel(1);
            getStatistics(spArea, spGFP);

            selectWindow(maxTitle);
            Stack.setChannel(2);
            getStatistics(spArea, spCY5);

            spotContent = spotContent +
                          fileName + "," + seriesBase + "," + (sp + 1) + "," +
                          spotNames[sp] + "," + spX[sp] + "," + spY[sp] + "," +
                          spotSize + "," + spGFP + "," + spCY5 + "\n";
        }
        run("Select None");

        // ── 2. Split channels → RGB via Merge Channels ────────────────────────
        chTags  = newArray("C1_GFP", "C2_CY5", "C3_BF");
        chSlots = newArray(MERGE_SLOT_C1, MERGE_SLOT_C2, MERGE_SLOT_C3);
        nSave   = minOf(nCh, 3);

        for (c = 1; c <= nSave; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=split_tmp duplicate channels=" + c);
            run("Merge Channels...", chSlots[c - 1] + "=split_tmp create");
            run("RGB Color");
            saveAs("Tiff", splitDir + seriesBase + "_" + chTags[c - 1] + ".tif");
            close();
        }

        // ── 3. Merge C1 (green) + C2 (red) → RGB ─────────────────────────────
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C1 duplicate channels=1");
        selectWindow(maxTitle);
        run("Duplicate...", "title=forMerge_C2 duplicate channels=2");

        run("Merge Channels...",
            MERGE_SLOT_C1 + "=forMerge_C1 " +
            MERGE_SLOT_C2 + "=forMerge_C2 " +
            "create");
        run("RGB Color");
        saveAs("Tiff", mergeDir + seriesBase + "_merged_C1C2.tif");
        close();

        // ── 6b. Spot-marked image (drawn on merged RGB) ───────────────────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif");
        markedTitle = getTitle();

        setColor(SPOT_R, SPOT_G, SPOT_B);
        setLineWidth(SPOT_LW);
        setFont("SansSerif", SPOT_FONT, "bold antialiased");

        for (sp = 0; sp < 5; sp++) {
            // Filled rectangle outline
            drawRect(spX[sp], spY[sp], spotSize, spotSize);
            // Label just above the rectangle; clamp so it stays inside image
            labelY = spY[sp] - 4;
            if (labelY < SPOT_FONT) labelY = spY[sp] + SPOT_FONT + 4;
            drawString("S" + (sp + 1) + " " + spotNames[sp], spX[sp] + 2, labelY);
        }
        run("Select None");
        saveAs("Tiff", spotDir + seriesBase + "_spots_marked.tif");
        close();

        // ── 4. Montage: merged / C1 GFP / C2 CY5 (1 column) ─────────────────
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

// ── Write all CSVs to disk ────────────────────────────────────────────────────
File.saveString(csvContent,     csvPath);
File.saveString(summaryContent, summaryPath);
File.saveString(spotContent,    spotPath);

print("---");
print("All done.");
print("Detail CSV    : " + csvPath);
print("Summary CSV   : " + summaryPath);
print("Spot CSV      : " + spotPath);
print("Spot images   : " + spotDir);
print("Output        : " + outputDir);
