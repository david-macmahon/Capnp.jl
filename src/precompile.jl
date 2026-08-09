# Precompile a representative build+read+pack workflow so that the common
# hot paths are specialized during package precompilation rather than on
# first use. The work performed here is executed only during
# precompilation; `@compile_workload` elides it on normal `using`.

@compile_workload begin
    # ----- Build side -----
    # root: 2 data words, 5 pointer slots:
    #   slot 0 -> struct, slot 1 -> text, slot 2 -> data,
    #   slot 3 -> primitive list, slot 4 -> composite list
    mb = MessageBuilder()
    root = init_root_struct!(mb, 2, 5)

    set_int8!(root, 0, 0, 0x7f)
    set_int16!(root, 0, 0x7fff)
    set_int32!(root, 0, 0x7fffffff)
    set_int64!(root, 0, 0x7fffffffffffffff)
    set_uint8!(root, 1, 0, 0xff)
    set_uint16!(root, 1, 0xffff)
    set_uint32!(root, 1, 0xffffffff)
    set_uint64!(root, 1, 0xffffffffffffffff)
    set_bool!(root, 1, 0, true)
    set_float32!(root, 1, 1.0f0)
    set_float64!(root, 1, 1.0)

    set_text!(root, 1, "hello")
    set_data!(root, 2, UInt8[0x01, 0x02, 0x03])

    sub = alloc_struct!(root, 0, 1, 1)
    set_int64!(sub, 0, -1)
    set_text!(sub, 0, "inner")

    lb = alloc_list!(root, 3, INT64_LIST, 3)
    set_element!(lb, 0, UInt64(10))
    set_element!(lb, 1, UInt64(20))
    set_element!(lb, 2, UInt64(30))

    pl = alloc_composite_list!(root, 4, 2, 1, 1)
    set_int64!(list_element_struct(pl, 0), 0, 100)
    set_int64!(list_element_struct(pl, 1), 0, 200)

    bytes = write_message(mb)

    # ----- Read side -----
    mr, _ = read_message(bytes)
    rr = get_root(mr)
    get_int8(rr, 0, 0)
    get_int16(rr, 0)
    get_int32(rr, 0)
    get_int64(rr, 0)
    get_uint8(rr, 0, 0)
    get_uint16(rr, 0)
    get_uint32(rr, 0)
    get_uint64(rr, 0)
    get_bool(rr, 1, 0)
    get_float32(rr, 1)
    get_float64(rr, 1)
    get_text(rr, 1)
    get_data(rr, 2)
    sub_r = get_struct_field(rr, 0)
    get_int64(sub_r, 0)
    get_text(sub_r, 0)
    lr = get_list_field(rr, 3)
    list_length(lr)
    get_element(lr, 0)
    get_element(lr, 1)
    list_element(lr, 0)
    plr = get_list_field(rr, 4)
    list_length(plr)
    list_element_struct(plr, 0)
    list_element_struct(plr, 1)
    is_null(rr, 0)
    is_null(rr, 99)

    # ----- List read barriers (force specialization of _read_prim_list etc.) -----
    # `lr` is the Int64 list reader from slot 3; calling each barrier with n=0
    # triggers method specialization without reading any elements. PT_Text /
    # PT_Data have no _read_prim_list method (the dispatcher routes them to
    # _read_text_list / _read_data_list), so skip them here.
    for prim in instances(PrimitiveType)
        prim === PT_Text || prim === PT_Data || _read_prim_list(lr, 0, Val(prim))
    end
    _read_text_list(lr, 0)
    _read_data_list(lr, 0)
    # A composite (struct) list reader for the struct-list barrier: build a
    # tiny schema + one-element struct list so the barrier specializes against
    # a real ListReader and a resolved StructNode.
    begin
        sf2 = parse_schema("@0x1; struct S { x @0 :Int64; }")
        mb2 = MessageBuilder()
        root2 = init_root_struct!(mb2, 0, 1)
        cl = alloc_composite_list!(root2, 0, 1, 1, 0)
        set_int64!(list_element_struct(cl, 0), 0, 0)
        mr2, _ = read_message(write_message(mb2))
        rr2 = get_root(mr2)
        plr2 = get_list_field(rr2, 0)
        _read_struct_list(plr2, sf2, "S", 1, "", nothing)
    end

    # ----- Packed / agnostic -----
    packed = write_packed(mb)
    read_packed(packed)
    read_message_agnostic(bytes)
    read_message_agnostic(packed)
    looks_packed(bytes)
    looks_packed(packed)
    pack(bytes)
    unpack(packed)

    # ----- Wire helpers (force specialization) -----
    struct_pointer(5, 3, 7)
    list_pointer(2, INT64_LIST, 4)
    far_pointer(0, 1, false)
    element_words(INT64_LIST, 4)
    pointer_type(struct_pointer(0, 0, 0))
    pointer_offset(struct_pointer(0, 0, 0))
    struct_data_words(struct_pointer(0, 3, 0))
    struct_ptr_count(struct_pointer(0, 0, 7))
end

nothing
