#!/bin/bash
# adapt to mtk 6.6 by klozz <carlosj@klozz.dev>
set -e

EXTRACT_OTA=../../../prebuilts/extract-tools/linux-x86/bin/ota_extractor
MKDTBOIMG=../../../system/libufdt/utils/src/mkdtboimg.py
UNPACKBOOTIMG=../../../system/tools/mkbootimg/unpack_bootimg.py
ROM_ZIP=$1

error_handler() {
    if [[ -d $extract_out ]]; then
        echo "Error detected, cleaning temporal working directory $extract_out"
        rm -rf $extract_out
    fi
}

trap error_handler ERR

function usage() {
	echo "Usage: ./extract-files.sh <rom-zip>"
	exit 1
}

function get_path() {
	echo "$extract_out/$1"
}

function unpackbootimg() {
	$UNPACKBOOTIMG $@
}

function extract_ota() {
    $EXTRACT_OTA $@
}

if [[ ! -f $UNPACKBOOTIMG ]]; then
	echo "Missing $UNPACKBOOTIMG, are you on the correct directory?"
	exit 1
fi

if [[ ! -f $EXTRACT_OTA ]]; then
	echo "Missing $EXTRACT_OTA, are you on the correct directory and have built the ota_extractor target?"
	exit 1
fi

if [[ -z $ROM_ZIP ]] || [[ ! -f $ROM_ZIP ]]; then
	usage
fi

# Clean and create needed directories
for dir in ./modules/vendor_dlkm ./modules/system_dlkm ./modules/odm_dlkm ./modules/vendor_boot ./images ./images/dtbs; do
    rm -rf $dir
    mkdir -p $dir
done

# Extract the OTA package
extract_out=$(mktemp -d)
echo "Using $extract_out as working directory"

echo "Extracting the payload from $ROM_ZIP"
unzip $ROM_ZIP payload.bin -d $extract_out

echo "Extracting OTA images"
extract_ota -payload $extract_out/payload.bin -output_dir $extract_out -partitions boot,dtbo,vendor_boot,vendor_dlkm,system_dlkm

# BOOT
echo "Extracting the kernel image from boot.img"
out=$extract_out/boot-out
mkdir $out

echo "Extracting at $out"
unpackbootimg --boot_img $(get_path boot.img) --out $out --format mkbootimg

echo "Done. Copying the kernel"
cp $out/kernel ./images/kernel

# Detectar formato y renombrar
fmt=$(file -b ./images/kernel)
if echo "$fmt" | grep -q "LZ4"; then
    mv ./images/kernel ./images/Image.lz4
elif echo "$fmt" | grep -q "gzip"; then
    mv ./images/kernel ./images/Image.gz
elif echo "$fmt" | grep -q "XZ"; then
    mv ./images/kernel ./images/Image.xz
fi

echo "Done"

# VENDOR_BOOT
echo "Extracting the ramdisk kernel modules and DTB"
out=$extract_out/vendor_boot-out
mkdir $out

echo "Extracting at $out"
unpackbootimg --boot_img $(get_path vendor_boot.img) --out $out --format mkbootimg

echo "Done. Extracting the ramdisk"
mkdir $out/ramdisk
unlz4 $out/vendor_ramdisk00 $out/vendor_ramdisk
cpio -i -F $out/vendor_ramdisk -D $out/ramdisk

echo "Copying all ramdisk modules"
for module in $(find $out/ramdisk -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist"); do
	cp $module ./modules/vendor_boot/
done

# VENDOR_DLKM
echo "Extracting the dlkm kernel modules"
out=$extract_out/vendor_dlkm

echo "Extracting at $out"
fsck.erofs --extract="$out" $(get_path vendor_dlkm.img)

echo "Done. Extracting the vendor dlkm"

echo "Copying all vendor dlkm modules"
for module in $(find $out/lib -name "*.ko" -o -name "modules.load*" -o -name "modules.blocklist"); do
	cp $module ./modules/vendor_dlkm/
done

# SYSTEM_DLKM
echo "Extracting the system_dlkm kernel modules"
out=$extract_out/system_dlkm
mkdir -p "$out"

echo "Extracting at $out"
# Asegúrate de usar --extract=directorio sin el signo = si falla, 
# pero generalmente es fsck.erofs --extract=DIR IMG
fsck.erofs --extract="$out" "$(get_path system_dlkm.img)"

# Verificamos si realmente extrajo algo
if [ -d "$out/lib/modules" ]; then
    echo "Done. Copying all system dlkm modules"
    cp -rv "$out/lib/modules/"* ./modules/system_dlkm/
else
    echo "WARNING: system_dlkm extraction failed or empty. Checking root..."
    # A veces el contenido está en la raíz de la imagen
    cp -rv "$out/"* ./modules/system_dlkm/ || echo "Failed to find any modules."
fi

# Extract DTBO and DTBs
echo "Extracting DTBO and DTBs"
cp -fv "${extract_out}/dtbo.img" ./images/dtbo.img

# Verificamos si el archivo dtb existe antes de intentar extraerlo
DTB_FILE="${extract_out}/vendor_boot-out/dtb"

if [ -f "$DTB_FILE" ]; then
    curl -sSL "https://raw.githubusercontent.com/PabloCastellano/extract-dtb/master/extract_dtb/extract_dtb.py" > ${extract_out}/extract_dtb.py
    
    python3 "${extract_out}/extract_dtb.py" "$DTB_FILE" -o "${extract_out}/dtbs" > /dev/null
    
    # Copiamos si se generaron archivos
    if [ "$(ls -A ${extract_out}/dtbs)" ]; then
        find "${extract_out}/dtbs" -type f -name "*.dtb" -exec cp {} ./images/dtbs/ \;
        echo "DTBs extracted successfully."
    else
        echo "Error: extract_dtb.py no generó archivos. El formato del DTB podría ser distinto."
    fi
else
    echo "Error: No se encontró el archivo dtb en ${extract_out}/vendor_boot-out/"
    # Debug: lista el contenido para saber dónde está
    ls -R "${extract_out}/vendor_boot-out/"
fi

# Add touch modules to vendorboot for recovery
#for module in goodix_core_rodin.ko focaltech_touch_rodin.ko xiaomi_touch_rodin.ko xiaomi_spi_tee.ko; do
#    cp modules/vendor_dlkm/$module modules/vendor_boot/
#    echo $module >> modules/vendor_boot/modules.load.recovery
#done

echo "Moving modules.load files to root with specific names..."
# vendor_boot: modules.load -> modules.load.vendor_ramdisk
if [ -f ./modules/vendor_boot/modules.load ]; then
    mv ./modules/vendor_boot/modules.load ./modules.load.vendor_ramdisk
    echo "Moved modules.load to modules.load.vendor_ramdisk"
fi

# vendor_boot: modules.load.recovery -> modules.load.recovery
if [ -f ./modules/vendor_boot/modules.load.recovery ]; then
    mv ./modules/vendor_boot/modules.load.recovery ./modules.load.recovery
    echo "Moved modules.load.recovery to root"
fi

# system_dlkm: modules.load -> modules.load.system
if [ -f ./modules/system_dlkm/modules.load ]; then
    mv ./modules/system_dlkm/modules.load ./modules.load.system
    echo "Moved modules.load to modules.load.system"
fi

if [ -f ./modules/system_dlkm/modules.alias ]; then
    echo "cleaning..."
    rm modules/system_dlkm/modules.alias
fi

if [ -f ./modules/system_dlkm/modules.dep ]; then
    echo "cleaning..."
    rm ./modules/system_dlkm/modules.dep
fi

if [ -f ./modules/system_dlkm/modules.softdep ]; then
    echo "cleaning..."
    rm ./modules/system_dlkm/modules.softdep 
fi

# vendor_dlkm: modules.load -> modules.load.vendor
if [ -f ./modules/vendor_dlkm/modules.load ]; then
    mv ./modules/vendor_dlkm/modules.load ./modules.load.vendor
    echo "Moved modules.load to modules.load.vendor"
fi

if [ -f images/dtbs/01_dtbdump_MT6899.dtb ]; then
    rm -rfv ./images/dtbs/01_dtbdump_MT6899.dtb
fi

# We have yuki kernel now
git checkout images/dtbs/mt6899.dtb images/Image.lz4

# etc.

rm -rf $extract_out
echo "Extracted files successfully"