# Description: Loops the install url for faster and easier refreshing.
# PERSISTENT: FALSE

while true; do
    clear
    bash <(curl -fsSL "https://raw.githubusercontent.com/technicdawn-stack/PiTweaks/main/install.sh")
    echo ""
    read -p "Press [Enter] to fetch the latest cache and re-run..."
done
