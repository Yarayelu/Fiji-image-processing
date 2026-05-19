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
        gfpTitle = "C1-" + imgTitle;
        brightTitle = "C2-" + imgTitle;

        //if (isOpen(brightTitle)) {
        //    selectWindow(brightTitle);
        //    close();
        }

       

        // Save Brighfeild RGB
        selectWindow(brightTitle);
        //run("Brightness/Contrast...");
        //setMinAndMax(2547, 9348);
        run("RGB Color");
        
        run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "-TD.tif");
        close();
        
        // Save GFP RGB
        selectWindow(gfpTitle);
        //run("Brightness/Contrast...");
        //setMinAndMax(104, 10439);
        run("RGB Color");
        //run("Enhance Contrast", "saturated=0.01");
        run("Scale Bar...", "width=100 height=4 font=14 color=White background=None location=[Lower Right] bold");
        saveAs("Tiff", outputDir + base + "-TMR.tif");
        close();

       

        // Re-open saved RGBs to create stack
       
       
        //open(outputDir + base + "-GFP_RGB.tif");
        //open(outputDir + base + "-Bright_RGB.tif");

        //run("Images to Stack", "name=" + base + "_Stack title=[] use");
        //run("Scale Bar...", "width=20 height=4 font=14 color=White background=None location=[Lower Right] bold");
        //saveAs("Tiff", outputDir + base + "_GFP_Atto_Merged_STACK.tif");
        
        

        // Close all images
        while (nImages() > 0) {
            selectImage(nImages());
            close();
        }
    }
}
