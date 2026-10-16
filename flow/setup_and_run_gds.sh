#!/usr/bin/env bash
# =============================================================================
# setup_and_run_gds.sh -- Automated RTL-to-GDSII Runner for SARCATHON 2026
# =============================================================================
set -e

echo "=================================================================="
echo " SARCATHON 2026: Automated RTL-to-GDSII Flow (OpenLane / Sky130)"
echo "=================================================================="

# 1. Check if Docker is running
if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker is not installed or not in PATH."
    echo "Please install Docker Desktop or Docker in WSL first."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[*] Project Root: $PROJECT_ROOT"

# 2. Check if OpenLane repo and PDK exist in ~/openlane_sarcathon
WORK_DIR="$HOME/openlane_sarcathon"
mkdir -p "$WORK_DIR"

if [ ! -d "$WORK_DIR/OpenLane" ]; then
    echo "[*] Cloning OpenLane repository..."
    git clone --depth 1 https://github.com/The-OpenROAD-Project/OpenLane.git "$WORK_DIR/OpenLane"
fi

cd "$WORK_DIR/OpenLane"

# 3. Copy our design and RTL into OpenLane designs folder
DESIGN_DIR="$WORK_DIR/OpenLane/designs/axi4_pcie6_bridge_top"
mkdir -p "$DESIGN_DIR/src"

echo "[*] Copying RTL and configuration files to $DESIGN_DIR..."
cp "$PROJECT_ROOT"/rtl/*.v "$DESIGN_DIR/src/"
cp "$PROJECT_ROOT/flow/constraints.sdc" "$DESIGN_DIR/constraints.sdc"

# Create OpenLane config.json with local src paths
cat > "$DESIGN_DIR/config.json" << 'EOF'
{
    "DESIGN_NAME": "axi4_pcie6_bridge_top",
    "VERILOG_FILES": "dir::src/*.v",
    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": 10.0,
    "PNR_SDC_FILE": "dir::constraints.sdc",
    "FP_SIZING": "relative",
    "FP_CORE_UTIL": 35,
    "PL_TARGET_DENSITY": 0.45,
    "DIODE_INSERTION_STRATEGY": 3,
    "RUN_CVC": 1,
    "RUN_LVS": 1,
    "RUN_DRC": 1
}
EOF

echo "[*] Setup complete!"
echo "[*] Now running OpenLane flow to generate GDSII..."
make mount <<< "./flow.tcl -design axi4_pcie6_bridge_top -tag sarcathon_run1"

echo "=================================================================="
echo " FLOW COMPLETE!"
echo " Your final GDSII file is located at:"
echo " $DESIGN_DIR/runs/sarcathon_run1/results/final/gds/axi4_pcie6_bridge_top.gds"
echo "=================================================================="
