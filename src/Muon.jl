module Muon

import HDF5
import DataFrames: DataFrame
import CategoricalArrays: CategoricalArray

function readtable(tablegroup::HDF5.Group)
  tabledict = HDF5.read(tablegroup)
  
  if haskey(tabledict, "__categories")
    for (k, cats) in tabledict["__categories"]
      tabledict[k] = CategoricalArray(map(x -> cats[x+1], tabledict[k]))
    end
  end

  delete!(tabledict, "__categories")
  table = DataFrame(tabledict)
  
  table
end

mutable struct AnnData
  file::Union{HDF5.File,HDF5.Group}

  X::Array{Float64,2}
  obs::Union{DataFrame, Nothing}
  obsm::Union{Dict{String, Any}, Nothing}
  
  var::Union{DataFrame, Nothing}
  varm::Union{Dict{String, Any}, Nothing}

  function AnnData(file)
    adata = new(file)

    # Observations
    adata.obs = readtable(file["obs"])
    adata.obsm = HDF5.read(file["obsm"])

    # Variables
    adata.var = readtable(file["var"])
    adata.varm = HDF5.read(file["varm"])
    
    adata
  end
end

mutable struct MuData
  file::HDF5.File
  mod::Union{Dict{String, AnnData}, Nothing}

  obs::Union{DataFrame, Nothing}
  obsm::Union{Dict{String, Any}, Nothing}
  
  var::Union{DataFrame, Nothing}
  varm::Union{Dict{String, Any}, Nothing}
  
  function MuData(;file::HDF5.File)
    mdata = new(file)

    # Observations
    mdata.obs = readtable(file["obs"])
    mdata.obsm = HDF5.read(file["obsm"])

    # Variables
    mdata.var = readtable(file["var"])
    mdata.varm = HDF5.read(file["varm"])

    # Modalities
    mdata.mod = Dict{String,AnnData}()
    mods = HDF5.keys(mdata.file["mod"])
    for modality in mods
      adata = AnnData(mdata.file["mod"][modality])
      mdata.mod[modality] = adata
    end

    mdata
  end
end

function readh5mu(filename::AbstractString; backed=true)
  if backed
    fid = HDF5.h5open(filename)
  else
    fid = HDF5.h5open(filename, "r")
  end
  mdata = MuData(file = fid)
  return mdata 
end

Base.size(mdata::MuData) = (size(mdata.file["obs"]["_index"])[1], size(mdata.file["var"]["_index"])[1])

Base.getindex(mdata::MuData, modality::Symbol) = mdata.mod[String(modality)]
Base.getindex(mdata::MuData, modality::AbstractString) = mdata.mod[modality]

function Base.show(io::IO, mdata::MuData)
  compact = get(io, :compact, false)

  print(io, """MuData object $(size(mdata)[1]) \u2715 $(size(mdata)[2])""")
end

function Base.show(io::IO, ::MIME"text/plain", mdata::MuData)
    show(io, mdata)
end

export readh5mu, size
export AnnData, MuData

end # module
