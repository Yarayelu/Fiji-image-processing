// Batch ND2 Processor — Multi-series
// For each ND2 in the folder (handles multiple images per file):
//   1. Save every series as a separate TIF (MAX projection if z-stack)
//   2. Split channels → RGB TIFFs  (C1=GFP green | C2=CY5 red | C3=Brightfield grey)
//   3. Merge C1 + C2 → RGB TIFF
//   4. Montage: 1 column — Merged (top) / C1 GFP (middle) / C2 CY5 (bottom)
//   5. Measure mean fluorescence for C1 and C2 → CSV

// ── Channel colour slots ──────────────────────────────────────────────────────
// Fiji Merge Channels slots: c1=red c2=green c3=blue c4=grey c5=cyan c6=magenta c7=yellow
// These slots are used for BOTH the individual channel RGB saves AND the merge,
// guaranteeing that every channel looks identical in both outputs.
MERGE_SLOT_C1 = "c2";  // GFP        → green
MERGE_SLOT_C2 = "c1";  // CY5        → red
MERGE_SLOT_C3 = "c4";  // Brightfield→ grey (saved separately, not included in merge)

// ── Montage settings ──────────────────────────────────────────────────────────
BORDER_PX  = 10;   // gap between panels (px)
LABEL_SIZE = 24;   // white label font size (0 = no labels)

// ── Pick input folder ─────────────────────────────────────────────────────────
inputDir = getDirectory("Select folder containing ND2 files");
if (inputDir == "") exit("No folder selected — aborted.");

outputDir  = inputDir + "processed"       + File.separator;
rawDir     = outputDir + "1_RAW_TIF"      + File.separator;
splitDir   = outputDir + "2_channels"     + File.separator;
mergeDir   = outputDir + "3_merged"       + File.separator;
montageDir = outputDir + "4_montage"      + File.separator;
measDir    = outputDir + "5_measurements" + File.separator;

allDirs = newArray(outputDir, rawDir, splitDir, mergeDir, montageDir, measDir);
for (d = 0; d < allDirs.length; d++)
    if (!File.exists(allDirs[d])) File.makeDirectory(allDirs[d]);

// ── Initialise CSV content strings (written to disk once at the end) ─────────
// Building in memory avoids File.append double-newline blank rows.
csvPath     = measDir + "fluorescence_measurements.csv";
summaryPath = measDir + "mean_intensity_summary.csv";

csvContent     = "ND2_File,Series_ID,Channel,Mean_Intensity,Min,Max,StdDev,Area_px\n";
summaryContent = "ND2_File,Series_ID,GFP_mean_intensity,CY5_mean_intensity\n";

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

    // Query series count via Bio-Formats extensions (no dialog)
    run("Bio-Formats Macro Extensions");
    Ext.setId(filePath);
    Ext.getSeriesCount(nSeries);
    print("  Series found: " + nSeries);

    for (s = 0; s < nSeries; s++) {

        // Zero-padded series label: 01, 02 …
        if ((s + 1) < 10) seriesLabel = "0" + (s + 1);
        else               seriesLabel = "" + (s + 1);
        seriesBase = base + "_s" + seriesLabel;

        // ── Open one series ───────────────────────────────────────────────────
        // series_N is 1-based in Bio-Formats Importer
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
        maxTitle = getTitle();   // title refreshes after saveAs

        // ── 5. Measure C1 & C2 mean intensity on raw 16-bit image ────────────
        chLabels = newArray("GFP_C1", "CY5_C2");
        gfpMean  = 0;
        cy5Mean  = 0;
        for (c = 1; c <= 2; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=meas_ch duplicate channels=" + c);
            getStatistics(areaPx, meanVal, minVal, maxVal, stdVal);
            // Append to detail content string
            csvContent = csvContent +
                         fileName + "," + seriesBase + "," + chLabels[c-1] + "," +
                         meanVal  + "," + minVal + "," + maxVal + "," + stdVal + "," + areaPx + "\n";
            if (c == 1) gfpMean = meanVal;
            else        cy5Mean = meanVal;
            close();
        }
        // Append to summary content string (one row per series, ND2 file name included)
        summaryContent = summaryContent +
                         fileName + "," + seriesBase + "," + gfpMean + "," + cy5Mean + "\n";

        // ── 2. Split channels → RGB via Merge Channels (same slot as in step 3) ─
        // Using Merge Channels (rather than LUT assignment) for each channel
        // guarantees the colour is pixel-for-pixel identical to how that channel
        // appears inside the multi-channel merged image.
        chTags  = newArray("C1_GFP", "C2_CY5", "C3_BF");
        chSlots = newArray(MERGE_SLOT_C1, MERGE_SLOT_C2, MERGE_SLOT_C3);
        nSave   = minOf(nCh, 3);

        for (c = 1; c <= nSave; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=split_tmp duplicate channels=" + c);
            // Merge single channel into its colour slot → identical rendering to merged image
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
        mergedTitle = getTitle();
        run("RGB Color");
        saveAs("Tiff", mergeDir + seriesBase + "_merged_C1C2.tif");
        close();

        // ── 4. Montage: merged / C1 GFP / C2 CY5 (1 column) ─────────────────
        open(mergeDir + seriesBase + "_merged_C1C2.tif"); panelMerge = getTitle();
        open(splitDir + seriesBase + "_C1_GFP.tif");      panelC1    = getTitle();
        open(splitDir + seriesBase + "_C2_CY5.tif");      panelC2    = getTitle();

        // Burn white text label onto each panel
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

        // Stack 3 panels then make 1-column montage
        run("Images to Stack", "name=montage_stack title=[] use");
        run("Make Montage...",
            "columns=1 rows=3 scale=1 border=" + BORDER_PX + " font=0 use");
        saveAs("Tiff", montageDir + seriesBase + "_montage.tif");
        close();
        if (isOpen("montage_stack")) { selectWindow("montage_stack"); close(); }

        // ── Cleanup this series ───────────────────────────────────────────────
        if (isOpen(maxTitle)) { selectWindow(maxTitle); close(); }
        print("    s" + seriesLabel + " done.");
    }

    Ext.close();
    print("  -> " + outputDir);
}

setBatchMode(false);

// ── Write CSVs to disk (single write per file = no blank rows) ───────────────
File.saveString(csvContent,     csvPath);
File.saveString(summaryContent, summaryPath);

print("---");
print("All done.");
print("Detail CSV : " + csvPath);
print("Summary CSV: " + summaryPath);
print("Output     : " + outputDir);
