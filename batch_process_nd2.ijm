// Batch ND2 Processor
// For each ND2 in the input folder:
//   1. Max Intensity Projection across all z-slices
//   2. Split channels → save each as RGB TIFF
//   3. Merge channels → save composite as RGB TIFF

// ── Channel colours for merge (edit if your channel order differs) ──────────
// Fiji merge order: C1=red, C2=green, C3=blue, C4=grey, C5=cyan, C6=magenta, C7=yellow
// Adjust the array below to match your staining (one entry per channel, 1-indexed)
channelColors = newArray("Red", "Green", "Blue", "Grey", "Cyan", "Magenta", "Yellow");

// ── Pick input folder ────────────────────────────────────────────────────────
inputDir = getDirectory("Select folder containing ND2 files");
if (inputDir == "") exit("No folder selected — aborted.");

outputDir = inputDir + "processed" + File.separator;
if (!File.exists(outputDir)) File.makeDirectory(outputDir);

// Sub-folders
maxDir     = outputDir + "1_MAX"      + File.separator;
splitDir   = outputDir + "2_channels" + File.separator;
mergeDir   = outputDir + "3_merged"   + File.separator;
for (d = 0; d < 3; d++) {
    dirs = newArray(maxDir, splitDir, mergeDir);
    if (!File.exists(dirs[d])) File.makeDirectory(dirs[d]);
}

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

setBatchMode(true);  // headless — much faster

// ── Process each file ────────────────────────────────────────────────────────
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
    print("  " + width + "x" + height + "  C=" + channels + "  Z=" + slices + "  T=" + frames);

    // ── 1. Max Intensity Projection ──────────────────────────────────────────
    selectWindow(rawTitle);
    if (slices > 1)
        run("Z Project...", "projection=[Max Intensity] all");
    else
        run("Duplicate...", "title=MAX_tmp duplicate");  // single slice: just copy

    maxTitle = getTitle();

    // Save raw MAX (16-bit/32-bit, preserves data)
    selectWindow(maxTitle);
    saveAs("Tiff", maxDir + base + "_MAX.tif");
    maxTitle = getTitle();  // title updates after saveAs

    // ── 2. Split channels and save each as RGB ───────────────────────────────
    selectWindow(maxTitle);
    getDimensions(w, h, nCh, nZ, nT);

    for (c = 1; c <= nCh; c++) {
        selectWindow(maxTitle);
        // Extract single channel as a new image
        run("Duplicate...", "title=ch_tmp duplicate channels=" + c);
        chTitle = getTitle();

        // Convert to 8-bit RGB for saving
        run("Grays");          // apply greyscale LUT before RGB conversion
        run("RGB Color");
        saveAs("Tiff", splitDir + base + "_MAX_C" + c + ".tif");
        close();
    }

    // ── 3. Merge channels and save as RGB ────────────────────────────────────
    selectWindow(maxTitle);
    getDimensions(w, h, nCh, nZ, nT);

    if (nCh == 1) {
        // Single channel — just convert to RGB
        selectWindow(maxTitle);
        run("Duplicate...", "title=merge_tmp duplicate");
        run("RGB Color");
        saveAs("Tiff", mergeDir + base + "_MAX_merged.tif");
        close();
    } else {
        // Build the merge command dynamically
        mergeCmd = "";
        for (c = 1; c <= nCh; c++) {
            selectWindow(maxTitle);
            run("Duplicate...", "title=merge_C" + c + " duplicate channels=" + c);
            colorIdx = (c - 1) % channelColors.length;
            mergeCmd = mergeCmd + "c" + c + "=merge_C" + c + " ";
        }
        mergeCmd = mergeCmd + "create";
        run("Merge Channels...", mergeCmd);
        mergedTitle = getTitle();

        run("RGB Color");
        saveAs("Tiff", mergeDir + base + "_MAX_merged.tif");
        close();
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────
    // Close MAX and original (robust: close by title)
    if (isOpen(maxTitle))   { selectWindow(maxTitle);  close(); }
    if (isOpen(rawTitle))   { selectWindow(rawTitle);  close(); }

    print("  -> saved to: " + outputDir);
}

setBatchMode(false);
print("---");
print("All done. " + nd2List.length + " file(s) processed.");
print("Output folder: " + outputDir);
