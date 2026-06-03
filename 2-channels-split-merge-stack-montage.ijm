// The following macro can achieve the following function
// 1. remove brightfield channel or specific channel and merge the channels you want
// 2. Save you wanted channels and merged channels into RGB images
// 3. Make stack images in batch and autosave them
// 4. Make montage images in batch and autosave them

// Set input and output directories
inputDir = "/Users/leafylove/Desktop/nd2_input/";
outputDir = "/Users/leafylove/Desktop/nd2_output/";

fileList = getFileList(inputDir);

for (i = 0; i < fileList.length; i++) {
    if (endsWith(fileList[i], ".tif") || endsWith(fileList[i], ".tiff")) {
        open(inputDir + fileList[i]);
        imgTitle = getTitle();
        print("Processing: " + imgTitle);

        // Split channels
        run("Split Channels");

        // Get base name
        base = substring(imgTitle, 0, lengthOf(imgTitle) - 4);

        // Assume: C1 = GFP, C2 = Atto647, C3 = Brightfield (to be closed)
        af660Title = "C1-" + imgTitle;
        brightTitle = "C2-" + imgTitle;
        //brightTitle = "C3-" + imgTitle;

        //if (isOpen(brightTitle)) {
        //    selectWindow(brightTitle);
        //    close();
        }
		
		selectWindow(af660Title);
        // run("Brightness/Contrast...");
        // setMinAndMax(49, 32816);
        
        selectWindow(brightTitle);
        // run("Brightness/Contrast...");
        // setMinAndMax(214, 12822);
        
        // Merge GFP + Atto647
        run("Merge Channels...", "c1=[" + af660Title + "] c2=[" + brightTitle + "] create keep");
        run("Make Composite");
        //run("Apply LUT", "channel=1 lut=Green");
        //run("Apply LUT", "channel=2 lut=Red");
        
        
        run("RGB Color");
        //run("Enhance Contrast", "saturated=0.35");
        mergedTitle = base + "-Merged";
        rename(mergedTitle);
        run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + mergedTitle + ".tif");
        close();

        //Save Brighfeild RGB
        //selectWindow(brightTitle);
       
        //run("RGB Color");
        //run("Enhance Contrast", "saturated=0.01");
        //run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        //saveAs("Tiff", outputDir + base + "-Bright_RGB.tif");
        //close();
        
        // Save AF660 RGB
        selectWindow(af660Title);
        //run("Brightness/Contrast...");
        //setMinAndMax(2547, 9348);
        run("RGB Color");
        //run("Enhance Contrast", "saturated=0.01");
        run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "-AF660_RGB.tif");
        close();

        // Save Bright RGB
        selectWindow(brightTitle);
      	//run("Brightness/Contrast...");
        //setMinAndMax(2547, 9348);
        run("RGB Color");
        //run("Enhance Contrast", "saturated=0.35");
        run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "-bright_RGB.tif");
        close();

        // Re-open saved RGBs to create stack
        open(outputDir + mergedTitle + ".tif");
        open(outputDir + base + "-AF660_RGB.tif");
        open(outputDir + base + "-bright_RGB.tif");
        //open(outputDir + base + "-Bright_RGB.tif");

        run("Images to Stack", "name=" + base + "_Stack title=[] use");
        //run("Scale Bar...", "width=20 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "_GFP_Cherry_Merged_STACK.tif");
        
        // 创建 montage 并保存
        run("Make Montage...", "columns=1 rows=3 scale=0.5");
        //run("Scale Bar...", "width=20 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "_montage.tif");
        close();


        // Close all images
        while (nImages() > 0) {
            selectImage(nImages());
            close();
        }
    }
