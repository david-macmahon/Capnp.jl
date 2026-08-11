module CapnProto

using Mmap
using PrecompileTools: @compile_workload

export MessageBuilder, MessageReader, MmapMessageReader
export StructBuilder, ListBuilder, StructReader, ListReader
export init_root_struct!, init_root_list!
export get_root
export alloc_struct!, alloc_list!, alloc_composite_list!
export set_int8!, set_int16!, set_int32!, set_int64!
export set_uint8!, set_uint16!, set_uint32!, set_uint64!
export set_bool!, set_float32!, set_float64!
export set_text!, set_data!
export get_int8, get_int16, get_int32, get_int64
export get_uint8, get_uint16, get_uint32, get_uint64
export get_bool, get_float32, get_float64
export get_text, get_data
export get_struct_field, get_list_field
export list_length, list_element, list_element_struct
export is_null
export write_message, read_message, read_message_mmap, read_message_mmap_checked
export write_packed, read_packed
export pack, unpack
export looks_packed, read_message_agnostic
export ispacked
export SchemaFile, StructNode, EnumNode, InterfaceNode, ConstNode
export StructField, EnumValue, InterfaceMethod
export PrimitiveType, PT_Void, PT_Bool, PT_Int8, PT_Int16, PT_Int32, PT_Int64
export PT_UInt8, PT_UInt16, PT_UInt32, PT_UInt64, PT_Float32, PT_Float64, PT_Text, PT_Data
export parse_schema_file, parse_schema
export read_struct, write_struct!
export build_message, parse_message, parse_struct
export struct_pointer, list_pointer, far_pointer
export pointer_type, pointer_offset, struct_data_words, struct_ptr_count
export list_element_count, list_element_size, far_is_double, far_offset, far_segment_id
export element_words
export STRUCT_POINTER, LIST_POINTER, FAR_POINTER
export VOID_LIST, BOOL_LIST, INT8_LIST, INT16_LIST, INT32_LIST, INT64_LIST
export FLOAT32_LIST, FLOAT64_LIST, POINTER_LIST, COMPOSITE_LIST
export set_element!, set_text_element!
export get_element, get_text_element, get_byte
export parse_messages, MessageIterator, with_offsets, OffsetMessageIterator
export MessageStreamError, TruncatedMessageError, CorruptedMessageError

include("wire.jl")
include("message.jl")
include("builder.jl")
include("reader.jl")
include("packed.jl")
include("streaming.jl")
include("schema.jl")
include("schema_parser.jl")
include("typed.jl")

include("precompile.jl")

end
