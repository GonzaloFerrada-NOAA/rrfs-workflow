import sys
import xarray as xr

def main():
    # Usage: python add_nc.py "out.nc" "var1,var2" "file1.nc" "file2.nc" ...
    out_file = sys.argv[1]
    var_list = sys.argv[2].split(',')
    in_files = sys.argv[3:]

    running_total = None

    for f in in_files:
        # 1. Open individual file lazily
        with xr.open_dataset(f) as ds:
            # 2. Select only variables that actually exist in this file
            existing_vars = [v for v in var_list if v in ds.data_vars]
            subset = ds[existing_vars]

            # 3. Add to the running total
            if running_total is None:
                running_total = subset
            else:
                # This performs an element-wise add where coordinates match
                running_total = running_total + subset
            ds.close()

    # 4. Compute and save
    if running_total is not None:
        # Optional: ensure metadata is kept
        running_total.compute().to_netcdf(out_file,engine="netcdf4", format="NETCDF4")
        print(f"Done. Summed {len(in_files)} files into {out_file}")
    else:
        print("No matching variables found.")

if __name__ == "__main__":
    main()

