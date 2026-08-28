#!/bin/bash
clear

# Description: Thermodynamic ice calculator with automated Tkinter installation wrapper.
#PERSISTENT: FALSE

PYTHON_APP_PATH="/tmp/ice_calculator_ui.py"

# Check and install python3-tk dependency automatically on Debian/Raspberry Pi OS
if ! python3 -c "import tkinter" &> /dev/null; then
    echo "Tkinter not found. Installing python3-tk automatically..."
    sudo apt-get update -y && sudo apt-get install -y python3-tk
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install python3-tk automatically. Please run: sudo apt install python3-tk"
        exit 1
    fi
fi

# Write or overwrite the latest Python UI script on every run
cat << 'EOF' > "$PYTHON_APP_PATH"
import tkinter as tk
from tkinter import ttk

class IceCalculatorApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Thermal Ice & Water Calculator")
        self.root.geometry("450x520")
        self.root.configure(bg="#0f172a")

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TLabel", background="#0f172a", foreground="#f8fafc", font=("Arial", 11))
        style.configure("TButton", font=("Arial", 11, "bold"), background="#3b82f6", foreground="#ffffff")

        title_label = ttk.Label(root, text="Thermal Equilibrium Engine", font=("Arial", 14, "bold"))
        title_label.pack(pady=15)

        form_frame = tk.Frame(root, bg="#1e293b", padx=15, pady=15)
        form_frame.pack(padx=20, fill="x", expand=True)

        self.entries = {}
        fields = [
            ("Water Volume (L)", "water_vol"),
            ("Initial Temp (°C)", "init_temp"),
            ("Final Temp (°C)", "final_temp"),
            ("Ice Weight (g)", "ice_weight")
        ]

        for i, (label_text, key) in enumerate(fields):
            lbl = tk.Label(form_frame, text=label_text, bg="#1e293b", fg="#94a3b8", font=("Arial", 10))
            lbl.grid(row=i, column=0, sticky="w", pady=8)
            
            ent = tk.Entry(form_frame, font=("Arial", 11), bg="#334155", fg="#f8fafc", insertbackground="white", relief="flat")
            ent.grid(row=i, column=1, sticky="ew", pady=8, padx=10)
            self.entries[key] = ent

        # Container Efficiency Dropdown
        lbl_eff = tk.Label(form_frame, text="Container Type", bg="#1e293b", fg="#94a3b8", font=("Arial", 10))
        lbl_eff.grid(row=4, column=0, sticky="w", pady=8)
        
        self.eff_var = tk.StringVar(value="Thin Plastic (~1.15)")
        eff_menu = ttk.Combobox(form_frame, textvariable=self.eff_var, state="readonly", values=[
            "Thin Plastic (~1.15)", 
            "Standard Metal (~1.05)", 
            "Vacuum Sealed (~1.00)"
        ])
        eff_menu.grid(row=4, column=1, sticky="ew", pady=8, padx=10)

        form_frame.columnconfigure(1, weight=1)

        btn_calc = tk.Button(root, text="Calculate Missing Field", command=self.solve_thermodynamics, bg="#2563eb", fg="white", activebackground="#1d4ed8", activeforeground="white", relief="flat", pady=8)
        btn_calc.pack(padx=20, pady=15, fill="x")

        self.status_lbl = tk.Label(root, text="Leave one field blank to auto-solve it.", bg="#0f172a", fg="#38bdf8", font=("Arial", 9, "italic"))
        self.status_lbl.pack(pady=5)

    def solve_thermodynamics(self):
        # Reset text color for all fields to normal white
        for key, ent in self.entries.items():
            ent.config(fg="#f8fafc")

        data = {}
        empty_key = None

        eff_mapping = {
            "Thin Plastic (~1.15)": 1.15,
            "Standard Metal (~1.05)": 1.05,
            "Vacuum Sealed (~1.00)": 1.00
        }
        eff = eff_mapping.get(self.eff_var.get(), 1.00)

        for key, ent in self.entries.items():
            val = ent.get().strip()
            if val == "":
                if empty_key is None:
                    empty_key = key
                else:
                    self.status_lbl.config(text="Error: Leave exactly ONE field blank.", fg="#f43f5e")
                    return
            else:
                try:
                    data[key] = float(val)
                except ValueError:
                    self.status_lbl.config(text=f"Error: Invalid number in {key}", fg="#f43f5e")
                    return

        if not empty_key:
            self.status_lbl.config(text="Error: Leave one field blank so the app can solve it.", fg="#f43f5e")
            return

        try:
            # 1. Solve for Final Temp
            if empty_key == "final_temp":
                v = data["water_vol"] * 1000.0
                ti = data["init_temp"]
                m_ice = data["ice_weight"]
                
                numerator = (v * 4.184 * ti) - (m_ice * 334.0 * eff)
                denominator = (v * 4.184) + (m_ice * 4.184 * eff)
                tf = numerator / denominator
                
                self.entries["final_temp"].insert(0, f"{tf:.2f}")
                self.entries["final_temp"].config(fg="#34d399") # Highlight solved field in mint green
                self.status_lbl.config(text="Successfully solved Final Temperature!", fg="#34d399")

            # 2. Solve for Ice Weight
            elif empty_key == "ice_weight":
                v = data["water_vol"] * 1000.0
                ti = data["init_temp"]
                tf = data["final_temp"]
                
                if tf >= ti:
                    self.status_lbl.config(text="Error: Final temp must be lower than initial temp.", fg="#f43f5e")
                    return

                target_drop = ti - tf
                heat_to_remove = v * 4.184 * target_drop * eff
                energy_per_g_ice = 334.0 + (4.184 * max(0.0, tf))
                m_ice = heat_to_remove / energy_per_g_ice

                self.entries["ice_weight"].insert(0, f"{m_ice:.2f}")
                self.entries["ice_weight"].config(fg="#34d399")
                self.status_lbl.config(text="Successfully solved Ice Weight!", fg="#34d399")

            # 3. Solve for Water Volume
            elif empty_key == "water_vol":
                ti = data["init_temp"]
                tf = data["final_temp"]
                m_ice = data["ice_weight"]
                
                target_drop = ti - tf
                energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                water_mass_g = energy_gained / (4.184 * target_drop * eff)
                v = water_mass_g / 1000.0

                self.entries["water_vol"].insert(0, f"{v:.2f}")
                self.entries["water_vol"].config(fg="#34d399")
                self.status_lbl.config(text="Successfully solved Water Volume!", fg="#34d399")

            # 4. Solve for Initial Temp
            elif empty_key == "init_temp":
                v = data["water_vol"] * 1000.0
                tf = data["final_temp"]
                m_ice = data["ice_weight"]
                
                energy_gained = m_ice * (334.0 + (4.184 * max(0.0, tf)))
                heat_needed = energy_gained * eff
                delta_t = heat_needed / (v * 4.184)
                ti = tf + delta_t

                self.entries["init_temp"].insert(0, f"{ti:.2f}")
                self.entries["init_temp"].config(fg="#34d399")
                self.status_lbl.config(text="Successfully solved Initial Temperature!", fg="#34d399")

        except Exception as e:
            self.status_lbl.config(text=f"Calculation Error: {str(e)}", fg="#f43f5e")

if __name__ == "__main__":
    root = tk.Tk()
    app = IceCalculatorApp(root)
    root.mainloop()
EOF

python3 "$PYTHON_APP_PATH"
