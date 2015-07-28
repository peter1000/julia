# This file is a part of Julia. License is MIT: http://julialang.org/license

module Mmap

const PAGESIZE = Int(@unix ? ccall(:jl_getpagesize, Clong, ()) : ccall(:jl_getallocationgranularity, Clong, ()))

# for mmaps not backed by files
type Anonymous <: IO
    name::AbstractString
    readonly::Bool
    create::Bool
end

Anonymous() = Anonymous("",false,true)
Base.isopen(::Anonymous) = true
Base.isreadable(::Anonymous) = true
Base.iswritable(a::Anonymous) = !a.readonly

const INVALID_HANDLE_VALUE = -1
# const used for zeroed, anonymous memory; same value on Windows & Unix; say what?!
gethandle(io::Anonymous) = INVALID_HANDLE_VALUE

gethandle(io::Base.File) = io.handle

# platform-specific mmap utilities
@unix_only begin

const PROT_READ     = convert(Cint,1)
const PROT_WRITE    = convert(Cint,2)
const MAP_SHARED    = convert(Cint,1)
const MAP_PRIVATE   = convert(Cint,2)
const MAP_ANONYMOUS = convert(Cint, @osx? 0x1000 : 0x20)
const F_GETFL       = convert(Cint,3)

gethandle(io::IO) = fd(io)

# Determine a stream's read/write mode, and return prot & flags appropriate for mmap
function settings(fd, shared::Bool)
    flags = shared ? MAP_SHARED : MAP_PRIVATE
    if fd == INVALID_HANDLE_VALUE
        flags |= MAP_ANONYMOUS
        prot = PROT_READ | PROT_WRITE
    else
        mode = ccall(:fcntl,Cint,(Cint,Cint),fd,F_GETFL)
        systemerror("fcntl F_GETFL", mode == -1)
        mode = mode & 3
        prot = mode == 0 ? PROT_READ : mode == 1 ? PROT_WRITE : PROT_READ | PROT_WRITE
        if prot & PROT_READ == 0
            throw(ArgumentError("mmap requires read permissions on the file (choose r+)"))
        end
    end
    return prot, flags, (prot & PROT_WRITE) > 0
end

# Before mapping, grow the file to sufficient size
# Note: a few mappable streams do not support lseek. When Julia
# supports structures in ccall, switch to fstat.
grow!(::Anonymous,o::Integer,l::Integer) = return
grow!(f::Base.File,o::Integer,l::Integer) = Base.FS.truncate(f, o + l)
function grow!(io::IO, offset::Integer, len::Integer)
    pos = position(io)
    filelen = filesize(io)
    if filelen < offset + len
        write(io, Base.zeros(UInt8,(offset + len) - filelen))
        flush(io)
    end
    seek(io, pos)
    return
end
end # @unix_only

@windows_only begin

const PAGE_READONLY          = UInt32(0x02)
const PAGE_READWRITE         = UInt32(0x04)
const PAGE_WRITECOPY         = UInt32(0x08)
const PAGE_EXECUTE_READ      = UInt32(0x20)
const PAGE_EXECUTE_READWRITE = UInt32(0x40)
const PAGE_EXECUTE_WRITECOPY = UInt32(0x80)
const FILE_MAP_COPY          = UInt32(0x01)
const FILE_MAP_WRITE         = UInt32(0x02)
const FILE_MAP_READ          = UInt32(0x04)
const FILE_MAP_EXECUTE       = UInt32(0x20)

function gethandle(io::IO)
    handle = Libc._get_osfhandle(RawFD(fd(io))).handle
    systemerror("could not get handle for file to map: $(Libc.FormatMessage())", handle == -1)
    return Int(handle)
end

settings(sh::Anonymous) = utf16(sh.name), sh.readonly, sh.create
settings(io::IO) = convert(Ptr{Cwchar_t},C_NULL), isreadonly(io), true
end # @windows_only

# core impelementation of mmap
function mmap{T,N}(io::IO,
                          ::Type{Array{T,N}}=Vector{UInt8},
                          dims::NTuple{N,Integer}=(div(filesize(io)-position(io),sizeof(T)),),
                          offset::Integer=position(io); grow::Bool=true, shared::Bool=true)
    # check inputs
    isopen(io) || throw(ArgumentError("$io must be open to mmap"))
    isbits(T)  || throw(ArgumentError("unable to mmap $T; must satisfy isbits(T) == true"))

    len = prod(dims) * sizeof(T)
    len > 0 || throw(ArgumentError("requested size must be > 0, got $len"))
    len < typemax(Int) - PAGESIZE || throw(ArgumentError("requested size must be < $(typemax(Int)-PAGESIZE), got $len"))

    offset >= 0 || throw(ArgumentError("requested offset must be ≥ 0, got $offset"))

    # shift `offset` to start of page boundary
    offset_page::FileOffset = div(offset, PAGESIZE) * PAGESIZE
    # add (offset - offset_page) to `len` to get total length of memory-mapped region
    mmaplen = (offset - offset_page) + len

    file_desc = gethandle(io)
    # platform-specific mmapping
     @unix_only begin
        prot, flags, iswrite = settings(file_desc, shared)
        iswrite && grow && grow!(io, offset, len)
        # mmap the file
        ptr = ccall(:jl_mmap, Ptr{Void}, (Ptr{Void}, Csize_t, Cint, Cint, Cint, FileOffset), C_NULL, mmaplen, prot, flags, file_desc, offset_page)
        systemerror("memory mapping failed", reinterpret(Int,ptr) == -1)
    end # @unix_only

    @windows_only begin
        name, readonly, create = settings(io)
        szfile = convert(Csize_t, len + offset)
        readonly && szfile > filesize(io) && throw(ArgumentError("unable to increase file size to $szfile due to read-only permissions"))
        handle = create ? ccall(:CreateFileMappingW, stdcall, Ptr{Void}, (Cptrdiff_t, Ptr{Void}, Cint, Cint, Cint, Cwstring),
                                file_desc, C_NULL, readonly ? PAGE_READONLY : PAGE_READWRITE, szfile >> 32, szfile & typemax(UInt32), name) :
                          ccall(:OpenFileMappingW, stdcall, Ptr{Void}, (Cint, Cint, Cwstring),
                            readonly ? FILE_MAP_READ : FILE_MAP_WRITE, true, name)
        handle == C_NULL && error("could not create file mapping: $(Libc.FormatMessage())")
        ptr = ccall(:MapViewOfFile, stdcall, Ptr{Void}, (Ptr{Void}, Cint, Cint, Cint, Csize_t),
                    handle, readonly ? FILE_MAP_READ : FILE_MAP_WRITE, offset_page >> 32, offset_page & typemax(UInt32), (offset - offset_page) + len)
        ptr == C_NULL && error("could not create mapping view: $(Libc.FormatMessage())")
    end # @windows_only
    # convert mmapped region to Julia Array at `ptr + (offset - offset_page)` since file was mapped at offset_page
    A = pointer_to_array(convert(Ptr{T}, UInt(ptr) + UInt(offset - offset_page)), dims)
    @unix_only finalizer(A, x -> systemerror("munmap", ccall(:munmap,Cint,(Ptr{Void},Int),ptr,mmaplen) != 0))
    @windows_only finalizer(A, x -> begin
        status = ccall(:UnmapViewOfFile, stdcall, Cint, (Ptr{Void},), ptr)!=0
        status |= ccall(:CloseHandle, stdcall, Cint, (Ptr{Void},), handle)!=0
        status || error("could not unmap view: $(Libc.FormatMessage())")
    end)
    return A
end

mmap{T<:Array,N}(file::AbstractString,
                 ::Type{T}=Vector{UInt8},
                 dims::NTuple{N,Integer}=(div(filesize(file),sizeof(eltype(T))),),
                 offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->mmap(io, T, dims, offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")::Array{eltype(T),N}

# using a length argument instead of dims
mmap{T<:Array}(io::IO, ::Type{T}, len::Integer, offset::Integer=position(io); grow::Bool=true, shared::Bool=true) =
    mmap(io, T, (len,), offset; grow=grow, shared=shared)
mmap{T<:Array}(file::AbstractString, ::Type{T}, len::Integer, offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->mmap(io, T, (len,), offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")::Vector{eltype(T)}

# constructors for non-file-backed (anonymous) mmaps
mmap{T<:Array,N}(::Type{T}, dims::NTuple{N,Integer}; shared::Bool=true) = mmap(Anonymous(), T, dims, Int64(0); shared=shared)
mmap{T<:Array}(::Type{T}, i::Integer...; shared::Bool=true) = mmap(Anonymous(), T, convert(Tuple{Vararg{Int}},i), Int64(0); shared=shared)

function mmap{T<:BitArray,N}(io::IOStream,
                             ::Type{T},
                             dims::NTuple{N,Integer},
                             offset::FileOffset=position(io); grow::Bool=true, shared::Bool=true)
    n = prod(dims)
    nc = Base.num_bit_chunks(n)
    chunks = mmap(io, Vector{UInt64}, (nc,), offset; grow=grow, shared=shared)
    if !isreadonly(io)
        chunks[end] &= Base._msk_end(n)
    else
        if chunks[end] != chunks[end] & Base._msk_end(n)
            throw(ArgumentError("the given file does not contain a valid BitArray of size $(join(dims, 'x')) (open with \"r+\" mode to override)"))
        end
    end
    B = BitArray{N}(ntuple(i->0,N)...)
    B.chunks = chunks
    B.len = n
    if N != 1
        B.dims = dims
    end
    return B
end

mmap{T<:BitArray,N}(file::AbstractString, ::Type{T}, dims::NTuple{N,Integer}, offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->mmap(io, T, dims, offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")::BitArray{N}

# using a length argument instead of dims
mmap{T<:BitArray}(io::IO, ::Type{T}, len::Integer, offset::Integer=position(io); grow::Bool=true, shared::Bool=true) =
    mmap(io, T, (len,), offset; grow=grow, shared=shared)
mmap{T<:BitArray}(file::AbstractString, ::Type{T}, len::Integer, offset::Integer=Int64(0); grow::Bool=true, shared::Bool=true) =
    open(io->mmap(io, T, (len,), offset; grow=grow, shared=shared), file, isfile(file) ? "r+" : "w+")::BitVector

# constructors for non-file-backed (anonymous) mmaps
mmap{T<:BitArray,N}(::Type{T}, dims::NTuple{N,Integer}; shared::Bool=true) = mmap(Anonymous(), T, dims, Int64(0); shared=shared)
mmap{T<:BitArray}(::Type{T}, i::Integer...; shared::Bool=true) = mmap(Anonymous(), T, convert(Tuple{Vararg{Int}},i), Int64(0); shared=shared)

# msync flags for unix
const MS_ASYNC = 1
const MS_INVALIDATE = 2
const MS_SYNC = 4

function sync!{T}(m::Array{T}, flags::Integer=MS_SYNC)
    @unix_only systemerror("msync", ccall(:msync, Cint, (Ptr{Void}, Csize_t, Cint), pointer(m), length(m)*sizeof(T), flags) != 0)
    @windows_only systemerror("could not FlushViewOfFile: $(Libc.FormatMessage())",
                    ccall(:FlushViewOfFile, stdcall, Cint, (Ptr{Void}, Csize_t), pointer(m), length(m)) == 0)
end
sync!(B::BitArray, flags::Integer=MS_SYNC) = sync!(B.chunks, flags)

end # module
