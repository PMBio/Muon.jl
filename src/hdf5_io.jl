function read_dataframe(tablegroup::HDF5.Group)
    columns = read_attribute(tablegroup, "column-order")

    havecat = false
    if haskey(tablegroup, "__categories")
        havecat = true
        catcols = tablegroup["__categories"]
    end

    if haskey(attributes(tablegroup), "_index")
        indexdsetname = read_attribute(tablegroup, "_index")
        rownames = read(tablegroup[indexdsetname])
    else
        rownames = nothing
    end

    df = DataFrame()

    for col in columns
        column = read(tablegroup, col)
        if havecat && haskey(catcols, col)
            cats = read(catcols, col)
            column = compress(CategoricalArray(map(x -> cats[x + 1], column)))
        end
        df[!, col] = column
    end

    return df, rownames
end

function read_matrix(f::HDF5.Dataset)
    mat = read(f)
    if ndims(mat) > 1
        mat = PermutedDimsArray(mat, ndims(mat):-1:1) # transpose for h5py compatibility
    end
    return mat
end

function read_matrix(f::HDF5.Group)
    enctype = read_attribute(f, "encoding-type")

    if enctype == "csc_matrix" || enctype == "csr_matrix"
        shape = read_attribute(f, "shape")
        iscsr = enctype[1:3] == "csr"

        indptr = read(f, "indptr")
        indices = read(f, "indices")
        data = read(f, "data")

        indptr .+= eltype(indptr)(1)
        indices .+= eltype(indptr)(1)

        # the row indices in every column need to be sorted
        @views for (colstart, colend) in zip(indptr[1:(end - 1)], indptr[2:end])
            sort!(indices[colstart:(colend - 1)], data[colstart:(colend - 1)])
        end

        if iscsr
            reverse!(shape)
        end
        mat = SparseMatrixCSC(shape..., indptr, indices, data)
        return iscsr ? mat' : mat
    else
        throw("unknown encoding $enctype")
    end
end

function read_dict_of_matrices(f::HDF5.Group)
    return Dict{String, AbstractArray{<:Number}}(key => read_matrix(f[key]) for key in keys(f))
end

read_auto(f::HDF5.Dataset) = (read_matrix(f), nothing)
function read_auto(f::HDF5.Group)
    enctype = read_attribute(f, "encoding-type")
    if enctype == "dataframe"
        return read_dataframe(f)
    elseif endswith(enctype, "matrix")
        return read_matrix(f), nothing
    else
        throw("unknown encoding $enctype")
    end
end

function read_dict_of_mixed(f::HDF5.Group)
    ret = Dict{String, Union{DataFrame, AbstractArray{<:Number}}}()
    for k in keys(f)
        ret[k] = read_auto(f[k])[1] # assume data frames are properly aligned, so we can discard rownames
    end
    return ret
end

function write_attr(parent::Union{HDF5.File, HDF5.Group}, name::AbstractString, args...; kwargs...)
    if haskey(parent, name)
        delete_object(parent, name)
    end
    write_impl(parent, name, args...; kwargs...)
end

function write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::AbstractDict{<:AbstractString, <:Any},
)
    if length(data) > 0
        g = create_group(parent, name)
        for (key, val) in data
            write_impl(g, key, val)
        end
    end
end

function write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::CategoricalVector,
)
    write_impl(parent, name, data.refs .- 0x1)
    write_impl(parent, "__categories/$name", levels(data))
    attributes(parent[name])["categories"] = HDF5.Reference(parent["__categories"], name)
end

function write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::AbstractDataFrame,
)
    g = create_group(parent, name)
    attrs = attributes(g)
    attrs["encoding-type"] = "dataframe"
    attrs["encoding-version"] = "0.1.0"
    attrs["column-order"] = names(data)

    for (name, column) in pairs(eachcol(data))
        write_impl(g, string(name), column)
    end
end

write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    ::Nothing,
    data::AbstractDataFrame,
) = write_impl(parent, name, data)

function write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    rownames::AbstractVector{<:AbstractString},
    data::AbstractDataFrame,
)
    write_impl(parent, name, data)
    idxname = "_index"
    columns = names(data)
    while idxname ∈ columns
        idxname = "_" * idxname
    end
    g = parent[name]
    write_impl(g, idxname, values(rownames))
    attributes(g)["_index"] = idxname
end

# see https://github.com/JuliaIO/HDF5.jl/issues/827
# and https://github.com/JuliaIO/HDF5.jl/issues/826
write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::Union{<:AbstractArray{Bool}, BitArray{1}};
    extensible::Bool=false,
    compress::UInt8=UInt8(9),
) = write_impl(parent, name, Int8.(data), extensible=extensible, compress=compress)

write_impl(parent::Union{HDF5.File, HDF5.Group}, name::AbstractString, data::SubArray) =
    write_impl(parent, name, copy(data))

function write_impl(
    parentgrp::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::AbstractArray;
    extensible::Bool=false,
    compress::UInt8=0x9,
)
    if ndims(data) > 1
        data =
            data isa PermutedDimsArray && typeof(data).parameters[3] == Tuple(ndims(data):-1:1) ?
            parent(data) : permutedims(data, ndims(data):-1:1) # transpose for h5py compatibility
    end                                             # copy because HDF5 apparently can't handle lazy Adjoints

    if extensible
        dims = (size(data), Tuple(-1 for _ in 1:ndims(data)))
    else
        dims = size(data)
    end
    dtype = datatype(data)
    write_impl_array(parentgrp, name, data, dtype, dims, compress)
end

function write_impl_array(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::AbstractArray{<:Number},
    dtype::HDF5.Datatype,
    dims::Tuple{Vararg{<:Integer}},
    compress::UInt8,
)
    chunksize = HDF5.heuristic_chunk(data)
    d = create_dataset(parent, name, dtype, dims, chunk=chunksize, compress=compress)
    write_dataset(d, dtype, data)
end

# variable-length strings cannot be compressed in HDF5
function write_impl_array(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::AbstractArray{<:AbstractString},
    dtype::HDF5.Datatype,
    dims::Tuple{Vararg{<:Integer}},
    compress::UInt8,
)
    d = create_dataset(parent, name, dtype, dims)
    write_dataset(d, dtype, data)
end

function write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::SparseMatrixCSC{<:Number, <:Integer};
    transposed=false,
)
    g = create_group(parent, name)
    attrs = attributes(g)
    attrs["encoding-type"] = transposed ? "csr_matrix" : "csc_matrix"
    attrs["encoding-version"] = "0.1.0"

    shape = collect(size(data))
    transposed && reverse!(shape)
    attrs["shape"] = shape
    write(g, "indptr", data.colptr .- 1, extensible=true)
    write(g, "indices", data.rowval .- 1, extensible=true)
    write(g, "data", data.nzval, extensible=true)
end

write_impl(
    prt::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::Adjoint{T, SparseMatrixCSC{T, V}} where {T <: Number, V <: Integer},
) = write_impl(prt, name, parent(data), transposed=true)

write_impl(
    parent::Union{HDF5.File, HDF5.Group},
    name::AbstractString,
    data::Union{HDF5.Dataset, SparseDataset, TransposedDataset},
) = copy_object(data, parent, name)

write_impl(parent::Union{HDF5.File, HDF5.Group}, name::AbstractString, ::Nothing) = nothing
