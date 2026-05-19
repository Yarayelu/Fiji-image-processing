// Batch ND2 Processor
// For each ND2 in the input folder:
//   1. Max Intensity Projection across all z-slices
//   2. Split channels → save each as RGB TIFF  (with scale bar)
//   3. Merge channels → save composite as RGB TIFF  (with scale bar)
//   4. Montage: 1 column — merged (top), C1 (middle), C2 (bottom)

// ── Channel colours for merge (edit if your channel order differs) ──────────
// Fiji merge order: C1=red, C2=green, C3=blue, C4=grey, C5=cyan, C6=magenta, C7=yellow
channelColors = newArray("Red", "Green", "Blue", "Grey", "Cyan", "Magenta", "Yellow");

// ── Montage settings ─────────────────────────────────────────────────────────
BORDER_PX   = 10;   // gap between panels in pixels
LABEL_SIZE  = 24;   // font size for panel labels (0 = no labels)
SCALE       = 1.0;  // resize each panel before tiling (0.5 = half size)

// ── Scale bar settings ───────────────────────────────────────────────────────
SB_UM       = 100;          // physical length in µm
SB_HEIGHT   = 8;            // bar thickness in pixels
SB_FONT     = 18;           // label font size
SB_COLOR    = "White";      // bar + text colour ("White", "Black", "Yellow" …)
SB_LOCATION = "Lower Right"; // "Lower Right", "Lower Left", "Upper Right", "Upper Left"
SB_BOLD     = true;         // bold text

// ── Pick input folder ────────────────────────────────────────────────────────
inputDir = getDirectory("Select folder containing ND2 files");
if (inputDir == "") exit("No folder selected — aborted.");

outputDir = inputDir + "processed" + File.separator;
if (!File.exists(outputDir)) File.makeDirectory(outputDir);

// Sub-folders
maxDir      = outputDir + "1_MAX"      + File.separator;
splitDir    = outputDir + "2_channels" + File.separator;
mergeDir    = outputDir + "3_merged"   + File.separator;
montageDir  = outputDir + "4_montage"  + File.separator;
allDirs = newArray(maxDir, splitDir, mergeDir, montageDir);
for (d = 0; d < allDirs.length; d++)
    if (!File.exists(allDirs[d])) File.makeDirectory(allDirs[d]);

// ── Collect ND2 files ────────────────────────────────────────────────────────
list = getFileList(inputDir);
nd2List = newArray(0);
for (i = 0; i < list.length; i++) {
    if (endsWith(toLowerCase(list[i]), ".nd2"))
        nd2List = Array.concat(nd2List, list[i]);
}

if (nd2List.length == 0) exit("No ND2 files found in:\n" + inputDir);

print("\\Clear");
print("=== Batch ND2 Processor ===");
print("Input : " + inputDir);
print("Output: " + outputDir);
print("Files found: " + nd2List.length);
print("---");

setBatchMode(true);

// ── Helper: burn a scale bar into the current RGB image ──────────────────────
// Reads pixel calibration from the active image, so must be called after
// RGB conversion while calibration is still attached.
function addScaleBar() {
    boldFlag = "";
    if (SB_BOLD) boldFlag = " bold";
    run("Scale Bar...",
        "width=" + SB_UM +
        " height=" + SB_HEIGHT +
        " font=" + SB_FONT +
        " color=" + SB_COLOR +
        " background=None" +
        " location=[" + SB_LOCATION + "]" +
        boldFlag);
}

// ── Process each file ─────────────────────────────────────────────────────────
for (f = 0; f < nd2List.length; f++) {
    fileName = nd2List[f];
    base     = substring(fileName, 0, lastIndexOf(fileName, "."));
    filePath = inputDir + fileName;

    print("[" + (f+1) + "/" + nd2List.length + "] " + fileName);

    // ── Open via Bio-Formats ─────────────────────────────────────────────────
    run("Bio-Formats Importer",
        "open=[" + filePath + "] " +
        "autoscale " +
        "color_mode=Default " +
        "open_all_series=false " +
        "split_focal=false " +
        "split_timepoints=false " +
        "view=Hyperstack " +
        "stack_order=XYCZT");

    rawTitle = getTitle();
    getDimensions(width, height, channels, slices, frames);

    // Capture pixel calibration from the raw file for the log
    getVoxelSize(vw, vh, vd, vunit);
    print("  " + width + "x" + height +
          "  C=" + channels + "  Z=" + slices + "  T=" + frames +
          "  pixel=" + vw + " " + vunit);
    if (vunit == "pixel" || vunit == "") {
        print("  WARNING: no spatial calibration found — scale bar will be pixel-based.");
    }

    // ── 1. Max Intensity Projection ──────────────────────────────────────────
    selectWindow(rawTitle);
    if (slices > 1)
        run("Z Project...", "projection=[Max Intensity] all");
    else
        run("Duplicate...", "title=MAX_tmp duplicate");

    maxTitle = getTitle();

    selectWindow(maxTitle);
    saveAs("Tiff", maxDir + base + "_MAX.tif");
    maxTitle = getTitle();

    // ── 2. Split channels, add scale bar, save each as RGB ───────────────────
    selectWindow(maxTitle);
    getDimensions(w, h, nCh, nZ, nT);

    for (c = 1; c <= nCh; c++) {
        selectWindow(maxTitle);
        run("Duplicate...", "title=ch_tmp duplicate channels=" + c);
        run("Grays");
        run("RGB Color");
        addScaleBar();
        saveAs("Tiff", splitDir + base + "_MAX_C" + c + ".tif");
        close();
    }

    // ── 3. Merge channels, add scale bar, save as RGB ────────────────────────
    selectWindow(maxTitle);
    getDimensions(w, h, nCh, nZ, nT);

    if (nCh == 1) {
        selectWindow(maxTitle);
        run("Duplicate...", "title=merge_tmp duplicate");
        run("RGB Color");
        addScaleBar();
        saveAs("Tiff", mergeDir + base + "_MAX_merged.tif");
        close();
    } else {
        mergeCmd = "";
        for (c = 1; c <= nCh; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=merge_C" + c + " duplicate channels=" + c);
            mergeCmd = mergeCmd + "c" + c + "=merge_C" + c + " ";
        }
        mergeCmd = mergeCmd + "create";
        run("Merge Channels...", mergeCmd);
        mergedTitle = getTitle();
        run("RGB Color");
        addScaleBar();
        saveAs("Tiff", mergeDir + base + "_MAX_merged.tif");
        close();
    }

    // ── 4. Montage: merged / C1 / C2 (1 column, top→bottom) ─────────────────
    // Re-open the saved RGBs — scale bars are already burned in
    open(mergeDir + base + "_MAX_merged.tif");  panelMerge = getTitle();
    open(splitDir + base + "_MAX_C1.tif");       panelC1    = getTitle();

    panelC2 = "";
    if (nCh >= 2) {
        open(splitDir + base + "_MAX_C2.tif");
        panelC2 = getTitle();
    }

    // Scale panels if requested
    if (SCALE != 1.0) {
        titles = newArray(panelMerge, panelC1, panelC2);
        for (p = 0; p < titles.length; p++) {
            if (titles[p] == "") continue;
            selectWindow(titles[p]);
            getDimensions(pw, ph, pc, ps, pt);
            run("Scale...", "x=" + SCALE + " y=" + SCALE +
                " width=" + round(pw*SCALE) + " height=" + round(ph*SCALE) +
                " interpolation=Bicubic average create");
            scaledT = getTitle();
            selectWindow(titles[p]); close();
            if (p == 0) panelMerge = scaledT;
            else if (p == 1) panelC1 = scaledT;
            else panelC2 = scaledT;
        }
    }

    // Add text label to each panel
    labels = newArray("Merged", "C1", "C2");
    panels = newArray(panelMerge, panelC1, panelC2);
    if (LABEL_SIZE > 0) {
        setFont("SansSerif", LABEL_SIZE, "bold antialiased");
        setColor(255, 255, 255);
        for (p = 0; p < panels.length; p++) {
            if (panels[p] == "") continue;
            selectWindow(panels[p]);
            drawString(labels[p], BORDER_PX, LABEL_SIZE + BORDER_PX);
        }
    }

    // Combine into a stack then make 1-column montage
    if (panelC2 != "") nPanels = 3;
    else nPanels = 2;

    if (nPanels == 3) {
        run("Images to Stack", "name=montage_stack title=[] use");
    } else {
        selectWindow(panelMerge); rename("panel_0");
        selectWindow(panelC1);    rename("panel_1");
        run("Images to Stack", "name=montage_stack title=panel_ use");
    }

    run("Make Montage...",
        "columns=1 rows=" + nPanels +
        " scale=1 border=" + BORDER_PX +
        " font=0 use");

    monTitle = getTitle();
    saveAs("Tiff", montageDir + base + "_montage.tif");
    close();

    if (isOpen("montage_stack")) { selectWindow("montage_stack"); close(); }

    // ── Cleanup ──────────────────────────────────────────────────────────────
    if (isOpen(maxTitle))  { selectWindow(maxTitle);  close(); }
    if (isOpen(rawTitle))  { selectWindow(rawTitle);  close(); }

    print("  -> saved to: " + outputDir);
}

setBatchMode(false);
print("---");
print("All done. " + nd2List.length + " file(s) processed.");
print("Output folder: " + outputDir);
