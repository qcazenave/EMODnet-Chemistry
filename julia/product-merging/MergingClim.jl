module MergingClim
using NCDatasets
using Dates
using Glob
using DataStructures
using GridInterpolations
using Interpolations
using Missings


# Create a specific structure to store the data of a climatology
struct RegionClimato
	name::String
	years::Array{Int64,1}
	depths::Array{Float32,1}
	lons::Array{Float32,1}
	lats::Array{Float32,1}
	field::Array{Union{Missing, Float32},4}
	fieldmasked::Array{Union{Missing, Float32},4}
end

"""
Generate a list dates (days since `dateref`) for the specified arrays
`years` and `months`
"""
function create_date_list(years::Array, months::Array, dateref::Date=Date(1900,1,1))
    datelist = []
    for year in years
        for month in months
            global daydiff
            d = Date(year, month, 15)
            daydiff = d - dateref
            push!(datelist, daydiff.value + 1)
        end
    end
    return datelist
end

"""
```julia
create_nc_merged(filename, longrid, latgrid, depthgrid, timegrid,
                 varname, standardname, longname, title, units, valex)
```

Create a netCDF file named `filename` with the coordinates taken from vectors
longrid, latgrid, depthgrid, timegrid.

The interpolated variable will be written by another function.
"""
function create_nc_merged(filename::String, longrid, latgrid, depthgrid, timegrid,
    varname::String, standardname::String, longname::String, title::String, units::String,
	valex::Float64=-999.)
    Dataset(filename, "c") do ds

        # Dimensions
        ds.dim["lon"] = length(longrid)
        ds.dim["nv"] = 2
        ds.dim["lat"] = length(latgrid)
        ds.dim["depth"] = length(depthgrid)
        ds.dim["time"] = length(timegrid)

        # Declare variables
        nclon = defVar(ds,"lon", Float64, ("lon",))
        nclon.attrib["standard_name"] = "longitude"
        nclon.attrib["long_name"] = "longitude"
        nclon.attrib["units"] = "degrees east"
        nclon.attrib["axis"] = "X"
        nclon.attrib["valid_min"] = -180.
        nclon.attrib["valid_max"] = 180.

        nclon_bnds = defVar(ds,"lon_bnds", Float64, ("nv", "lon"))

        nclat = defVar(ds,"lat", Float64, ("lat",))
        nclat.attrib["standard_name"] = "latitude"
        nclat.attrib["long_name"] = "latitude"
        nclat.attrib["units"] = "degrees north"
        nclat.attrib["axis"] = "Y"
        nclat.attrib["valid_min"] = -90.
        nclat.attrib["valid_max"] = 90.

        nclat_bnds = defVar(ds,"lat_bnds", Float64, ("nv", "lat"))

        ncdepth = defVar(ds,"depth", Float64, ("depth",))
        ncdepth.attrib["standard_name"] = "depth"
        ncdepth.attrib["units"] = "meters"
        ncdepth.attrib["axis"] = "Z"
        ncdepth.attrib["positive"] = "down"

        ncdepthnew_bnds = defVar(ds,"depthnew_bnds", Float64, ("nv", "depth"))

        nctime = defVar(ds,"time", Float64, ("time",))
        nctime.attrib["standard_name"] = "time"
        nctime.attrib["bounds"] = "time3_bnds"
        nctime.attrib["units"] = "days since 1900-01-01 00:00:00"
        nctime.attrib["calendar"] = "standard"
        nctime.attrib["climatology"] = "climatology_bounds"

        ncclimatology_bounds = defVar(ds,"climatology_bounds", Float64, ("nv", "time"))
        ncclimatology_bounds.attrib["units"] = "days since 1900-01-01 00:00:00"
        ncclimatology_bounds.attrib["calendar"] = "standard"

        # Interpolated variable
        # (should be obtained from one of the regional netCDF files)
        ncvarinterp = defVar(ds,varname, Float32, ("lon", "lat", "depth", "time"))
        ncvarinterp.attrib["long_name"] = longname
        ncvarinterp.attrib["standard_name"] = standardname
        ncvarinterp.attrib["_FillValue"] = Float32(valex)
        ncvarinterp.attrib["missing_value"] = Float32(valex)
        ncvarinterp.attrib["units"] = units

		# Interpolated variable masked using relative error threshold 0.5
        # (should be obtained from one of the regional netCDF files)
        ncvarinterp_masked = defVar(ds,varname*"_L2", Float32, ("lon", "lat", "depth", "time"))
        ncvarinterp_masked.attrib["long_name"] = longname * " masked using relative error threshold 0.5"
        ncvarinterp_masked.attrib["standard_name"] = standardname
        ncvarinterp_masked.attrib["_FillValue"] = Float32(valex)
        ncvarinterp_masked.attrib["missing_value"] = Float32(valex)
        ncvarinterp_masked.attrib["units"] = units

        # Global attributes
        ds.attrib["Conventions"] = "CF-1.0"
        ds.attrib["title"] = title
        ds.attrib["product_id"] = product_id
        ds.attrib["abstract"] = "Merge netCDF product obtained from the Arctic, Atlantic, Baltic, Black, Mediterranean and North seas"
        ds.attrib["Creation date"] = Dates.format(Dates.now(),  "yyyy-mm-dd HH:MM:SS")
        ds.attrib["Authors"] = "GHER, University of Liège"

        nclat[:] = latgrid;
        nclon[:] = longrid;
        nctime[:] = timegrid;
        ncdepth[:] = depthgrid;

    end
end


"""
```julia
get_file_list(datadir, varname, season)
```
Return a list of files located in `datadir`, containing the
variable `varname` for the season `season`.

`season` can take the values: Summer, Autumn, Winter, Spring

## Example
```julia
get_file("./data/EMODnet/", "chlorophyll-a", "Winter")
```
"""
function get_file_list(datadir::String, varname::String="", season::String="")::Array
    filelist = []
	# Varname with spaces instead of underscores
	varname2 = replace(varname, "_" => " ")
    for (root, dirs, files) in walkdir(datadir)
        for file in files
            if endswith(file, ".nc") &
                (occursin(varname, file) | occursin(varname2, file)) &
                occursin(uppercasefirst(season), root)
                push!(filelist, joinpath(root, file))
            end
        end
    end
    return filelist
end

"""
```julia
get_file_list_combined(datadir, varname)
```
Return a list of files corresponding to the combined products for the variable `varname`.


"""
function get_file_list_combined(datadir::String, varname::String)::Array
    filelist = []
    for (root, dirs, files) in walkdir(datadir)
        for file in files
            if endswith(file, ".nc") & (occursin(varname, file))
                push!(filelist, joinpath(root, file))
            end
        end
    end
    return filelist
end


"""
```julia
get_years(filename)
```
Extract the years (from the time variable) out of a netCDF file `filename`
"""
function get_years(filename::String)::Array
    Dataset(filename,"r") do ds
        global yeargrid
        dategrid = ds["time"][:]
        yeargrid = unique(Dates.year.(dategrid))
    end
    return yeargrid
end

"""
```julia
get_coords(filename)
```
Extract the years, longitudes, latitudes and depths
out of a netCDF file `filename`
"""
function get_coords(filename::String)
    Dataset(filename,"r") do ds
        global years, lonregion, latregion, depthregion
        dategrid = ds["time"][:]
        years = unique(Dates.year.(dategrid))
        @info size(years)
        @info typeof(years)
        lonregion = varbyattrib(ds, units="degrees_east")[1][:];
        latregion = varbyattrib(ds, units="degrees_north")[1][:];
        lonregion = coalesce.(lonregion, NaN)
        latregion = coalesce.(latregion, NaN)
        depthregion = ds["depth"][:]
        depthregion = coalesce.(depthregion, NaN)
    end
    return years, lonregion, latregion, depthregion
end


"""
```julia
get_closer_depth(depthgrid, depthlevel)
```
Get the 2 closest depths in vector `depthgrid`, to a select depth level `depthlevel`
If `depthlevel` is outside the interval defined by `depthgrid`, then nothing is returned.

## Examples
```julia
get_closer_depth([-10., -5., 7., 20], 1.);
(-5., 7.)
```

```julia
get_closer_depth([-10., -5., 7., 20], 1.);
(-5., 7.)
```
"""
function get_closer_depth(depthgrid::Array, depthlevel::Float64)
    # Check if we are within the depth interval
    if depthlevel >= minimum(depthgrid) && depthlevel <= maximum(depthgrid)
        Δdepth =  depthgrid .- depthlevel
        depthbelow = maximum(Δdepth[Δdepth .< 0]) + depthlevel
        depthabove = minimum(Δdepth[Δdepth .> 0]) + depthlevel;
        @debug("Depth below: " * string(depthbelow) * " m")
        @debug("Depth above: " * string(depthabove) * " m")
    else
        depthbelow = nothing
        depthabove = nothing
    end

    return depthbelow, depthabove
end

"""
```julia
w1, w2 = get_depth_weights(depthlevel, dmin, dmax)
```
Compute the weight for the linear interpolation, according to the depths.
If `depthlevel` is outside the interval defined by `dmin` and `dmax`,
then nothing is returned.

## Example
```julia
w1, w2 = get_depth_weights(-5., -20., 0.)
(0.75, 0.25)
```
"""
function get_depth_weights(depthlevel::Float64, dmin::Float64, dmax::Float64)
    if depthlevel <= dmax && depthlevel >= dmin
        Δ = dmax - dmin
        w1 = (depthlevel - dmin) / Δ
        w2 = 1 - w1
    else
        w1 = nothing
        w2 = nothing
    end

    return w1, w2
end

"""
```julia
get_depth_indices(depth, depthvector)
```
Return the indices of the depth levels from `depthvector` above and below
the depth level `depth`
"""
function get_depth_indices(depth::Float64, depthvector::Array{Float64})
    dmin, dmax = get_closer_depth(depthvector, depth)
    if dmin == nothing || dmax == nothing
        indmin = nothing
        indmax = nothing
    else
        indmin = findall(depthvector .== dmin)[1]
        indmax = findall(depthvector .== dmax)[1]
    end
    return indmin, indmax
end

"""
Get the field for the specificed variable, depth level, time period
from the file `filename`

```julia
get_var_level_time("mass_concentration_of_chlorophyll_a_in_sea_water",
 "Water_body_chlorophyll-a.4Danl.nc",
 12, 4)
```
"""
function get_var_level_time(var_stdname::String, filename::String, depthindex, timeindex::Array)
    Dataset(filename, "r") do ds1
        global field_depth
        field_depth = varbyattrib(ds1, standard_name=var_stdname)[1][:,:,:,timeindex]
    end
    return field_depth[:,:,depthindex]
end

"""
Get the masked field (relative error below 0.5) for the specificed variable, depth level, time period
from the file `filename`

```julia
get_masked_var_level_time("mass_concentration_of_chlorophyll_a_in_sea_water",
 "Water_body_chlorophyll-a.4Danl.nc", 12, 4)
```
"""
function get_masked_var_level_time(var_stdname::String, filename::String, depthindex, timeindex::Array)
    Dataset(filename, "r") do ds1
        global masked_field_depth
        masked_field_depth = varbyattrib(ds1, standard_name=var_stdname)[3][:,:,:,timeindex]
    end
    return masked_field_depth[:,:,depthindex]
end


"""
```julia
depth_interp(depth, depthvector, field)
```
Perform linear interpolation of the 4D variable `field` (read from a netCDF) defined on the
levels `depthvector` (vector) onto the depth level `depth`.

## Example
```julia
depth_interp(25., (0., 10., 20., 30.), temperature)
```
"""
function depth_interp(depth::Float64, depthvector::Array{Float64}, field::Array{Float64})
    dmin, dmax = get_closer_depth(depthvector, depth)
    indmin, indmax = get_depth_indices(depth, depthvector)
    # Compute weigths
    w1, w2 = get_depth_weights(depth, dmin, dmax)
    # Perform interpolation
    fieldinterp = w1 * field[:,:,indmin,:] + w2 * field[:,:,indmax,:]
    return fieldinterp
end

"""
```julia
interp_horiz(londata, latdata, data, longrid, latgrid)
```
Perform a bilinear interpolation of a 2D field defined by the coordinates
`(londata, latdata)` and the values `data`, onto the grid defined by the
vectors `longrid` and `latgrid`.
The interpolation is only performed over the area where data are available,
i.e., no extrapolation is performed.

"""
function interp_horiz(londata, latdata, data, longrid, latgrid)

    # Find the coordinates where the interpolation can be performed
    # (no extrapolation)
    goodlon = (longrid .<= londata[end]) .& (longrid .>= londata[1]);
    goodlat = (latgrid .<= latdata[end]) .& (latgrid .>= latdata[1]);

    # Remove the missing values?
    # Ask Alex if necessary
    #londata = coalesce.(londata, NaN)
    #latdata = coalesce.(latdata, NaN)
    #data = coalesce.(data, NaN);
    #data = convert(Array{Float32,2}, data)

    # Create the interpolator
    itp = Interpolations.interpolate((londata, latdata), data, Gridded(Linear()))
    #fieldinterpolated = itp(longrid, latgrid);

    # Perform the interpolation
    # (only within the domain of interest)
    lon_interp = longrid[goodlon]
    lat_interp = latgrid[goodlat]
    field_interpolated = itp(lon_interp, lat_interp);

    return lon_interp, lat_interp, field_interpolated, findall(goodlon), findall(goodlat)
end


"""
Simple function to get the name of the region from the file path
Could be done from the netCDF itself
"""
function get_region_name(datafile::String)::String
    return split(datafile,"/")[6]
end

"""
    sort_fields_time(datafile)

Sort chronologically the variables that depend on the time variable.

## Example
```julia-repl
sort_fields_time("Water_body_dissolved_oxygen_concentration_year.nc")
```
"""
function sort_fields_time(datafile::String)
    Dataset(datafile::String, "a") do ds

        @debug("Read time and sort index")
        times = ds["time"][:];
        sorting_index = sortperm(times);

        # Loop on the variables
        for varname in keys(ds)[1:end]

       		# Check if time is a dimension
            if "time" in dimnames(ds[varname])
                @info("Variable '$(varname)' contains 'time' dimension")
                #var = ds[varname][:]
                ndims = length(size(ds[varname][:]))
                @info("Number of dimensions: $(ndims)")
                if ndims == 1
                    ds[varname][:] = ds[varname][sorting_index]
                elseif ndims == 2
                    ds[varname][:] = ds[varname][:,sorting_index]
                elseif ndims == 3
                    ds[varname][:] = ds[varname][:,:,sorting_index]
                elseif ndims == 4
                    ds[varname][:] = ds[varname][:,:,:,sorting_index]
                else
                    @warn("Number of dimensions larger than 4")
                end
            end
        end
    end
end

function get_time_varlist(datafile::String)
    Dataset(datafile, "r") do ds

        times = ds["time"][:];
        sorting_index = sortperm(times);

        # Loop on the variables
        varlist = keys(ds)
        return sorting_index, varlist
    end
end

"""
    read_obs(datafile)

Read the observations from a netCDF file.

## Example
```julia-repl
julia> obslon, obslat, obsdepth, obstime, obsid = read_obs(datafile)
```
"""
function read_obs(datafile::String)

    NCDatasets.Dataset(datafile, "r") do nc

        obslon = Float64.(nc["obslon"][:])
        obslat = Float64.(nc["obslat"][:])
        obsdepth = Float64.(nc["obsdepth"][:])
        obstime = nc["obstime"][:]
        obsid = nc["obsid"][:]

        return obslon::Vector{Float64}, obslat::Vector{Float64},
        obsdepth::Vector{Float64}, obstime::Vector{DateTime},
        obsid::Matrix{Char}

    end
end

"""
    read_obs(filelist)

Read the observations from a list of netCDF files.

## Example
```julia-repl
julia> obslon, obslat, obsdepth, obstime, obsid = read_obs(datafilelist)
```
"""
function read_obs(datafilelist::Vector{String})

    # Empty vectors
    obslon = Vector{Float64}(undef, 0)
    obslat = Vector{Float64}(undef, 0)
    obsdepth = Vector{Float64}(undef, 0)
    obstime = Vector{DateTime}(undef, 0)
    obsid = Matrix{Char}(undef, 0, 0)

    for datafile in datafilelist
        @debug("Working on $(datafile)")
        NCDatasets.Dataset(datafile, "r") do nc

            obslon_n, obslat_n, obsdepth_n, obstime_n, obsid_n = read_obs(datafile)

            # Append the coordinate arrays
            append!(obslon, obslon_n);
            append!(obslat, obslat_n);
            append!(obsdepth, obsdepth_n);
            append!(obstime, obstime_n);

            obsid = merge_obsids(obsid, obsid_n)
        end
    end

    return obslon::Vector{Float64}, obslat::Vector{Float64},
    obsdepth::Vector{Float64}, obstime::Vector{DateTime},
    obsid::Matrix{Char}

end

"""
    merge_obsids(obsid1, obsid2)

Merge two arrays of observations

## Example
```julia-repl
julia> obsid = merge_obsids(obsid_old, obsid_new)
```
"""
function merge_obsids(obsid1::Matrix{Char}, obsid2::Matrix{Char})
    idlen1, nobs1 = size(obsid1)
    idlen2, nobs2 = size(obsid2)
    @debug(idlen1, idlen2, nobs1, nobs2);

    # Allocate new matrix for obsid
    obsid = Array{Char, 2}(undef, maximum((idlen1, idlen2)), nobs1 + nobs2);
    # Merge obsid's
    obsid[1:idlen1, 1:nobs1] = obsid1;
    obsid[1:idlen2, nobs1+1:nobs1 + nobs2] = obsid2;
    @debug(size(obsid));

    return obsid::Matrix{Char}
end

"""
    unique_obs(obslon, obslat, obsdepth, obstime, obsid)

Ensure uniqueness of observation vectors

## Example
```julia-repl
julia> obslon_u, obslat_u, obsdepth_u, obstime_u, obsid_u =
merge_obsids(obslon, obslat, obsdepth, obstime, obsid)
```
"""
function unique_obs(obslon::Vector{Float64}, obslat::Vector{Float64},
	obsdepth::Vector{Float64}, obstime::Vector{DateTime}, obsid::Matrix{Char})
	obsid_string = [String(obsid[:,ii]) for ii in 1:size(obsid)[2]];
	obsmatrix = hcat(obslon, obslat, obsdepth, obstime, obsid_string);
	obsmatrix = unique(obsmatrix, dims=1);
	obslon_u = Float64.(obsmatrix[:,1]);
	obslat_u = Float64.(obsmatrix[:,2]);
	obsdepth_u = Float64.(obsmatrix[:,3]);
	obstime_u = DateTime.(obsmatrix[:,4]);
	obsid_string_u = obsmatrix[:,5];

	# Process the obsid matrix (should be matrix of Char)
	obsid_u = Matrix{Char}(undef, size(obsid)[1], length(obslon_u))

	for ii = 1:length(obslat_u)
	    obsid_u[:,ii] = collect(obsid_string_u[ii])[1:size(obsid_u)[1]]
	end;

	return obslon_u, obslat_u, obsdepth_u, obstime_u, obsid_u
end


"""
    write_obs(datafile)

Write the new observations to a netCDF file from which the variables
corresponding to the observations (obslon, obslat etc) have been removed.

## Example
```julia-repl
julia> write_obs("merged.nc", obslon, obslat, obsdepth, obstime, obsid)
```
"""
function write_obs(datafile::String, obslon::Vector{Float64}, obslat::Vector{Float64},
    obsdepth::Vector{Float64}, obstime::Vector{Dates.DateTime},
    obsid::Matrix{Char})

    idlen, nobs = size(obsid)

    # Write in the new file
    NCDatasets.Dataset(datafile, "a") do nc
        nc.dim["idlen"] = idlen
        nc.dim["observations"] = nobs

        ncobsdepth = defVar(nc,"obsdepth", Float64, ("observations",),
            attrib = OrderedDict(
                        "units" => "meters",
                        "positive" => "down",
                        "long_name" => "depth of the observations",
                        "standard_name" => "depth"
                    )
                )

        ncobsid = defVar(nc,"obsid", Char, ("idlen", "observations"),
            attrib = OrderedDict(
                "long_name" => "observation identifier",
                "coordinates" => "obstime obsdepth obslat obslon",
                )
            )

        ncobslat = defVar(nc,"obslat", Float64, ("observations",),
            attrib = OrderedDict(
                "units" => "degrees_north",
                "long_name" => "latitude of the observations",
                "standard_name" => "latitude"
                )
            )

        ncobslon = defVar(nc,"obslon", Float64, ("observations",),
            attrib = OrderedDict(
                "units" => "degrees_east",
                "long_name" => "longitude of the observations",
                "standard_name" => "longitude"
                )
            )

        ncobstime = defVar(nc,"obstime", Float64, ("observations",),
            attrib = OrderedDict(
                "units" => "days since 1900-01-01 00:00:00",
                "long_name" => "time of the observations",
                "standard_name" => "time"
                )
            )

        ncobslon[:] = obslon
        ncobslat[:] = obslat
        ncobsdepth[:] = obsdepth
        ncobstime[:] = obstime
        ncobsid[:] = obsid;

        return
    end;
end;




end
