defmodule Voyager.Services.SSH.BcryptPbkdf do
  @moduledoc false

  import Bitwise

  @state_size 1042
  @s0 19
  @s1 19 + 256
  @s2 19 + 512
  @s3 19 + 768
  @magic "OxychromaticBlowfishSwatDynamite"

  pi_words = fn count ->
    bits = count * 32 + 64
    one = 1 <<< bits

    arctan_inv = fn x ->
      {div(one, x), 1}
      |> Stream.unfold(fn
        {0, _k} ->
          nil

        {term, k} ->
          {if(rem(k, 4) == 1, do: div(term, k), else: -div(term, k)), {div(term, x * x), k + 2}}
      end)
      |> Enum.sum()
    end

    frac = (16 * arctan_inv.(5) - 4 * arctan_inv.(239) - 3 * one) >>> 64
    for i <- (count - 1)..0//-1, do: frac >>> (i * 32) &&& 0xFFFFFFFF
  end

  @initial_state pi_words.(@state_size)

  @spec derive(binary(), binary(), pos_integer(), pos_integer()) :: binary()
  def derive(passphrase, salt, rounds, key_len) do
    sha2pass = :crypto.hash(:sha512, passphrase)
    stride = div(key_len + 31, 32)
    outs = List.to_tuple(for count <- 1..stride, do: block(sha2pass, salt, rounds, count))

    for i <- 0..(key_len - 1),
        into: <<>>,
        do: <<:binary.at(elem(outs, rem(i, stride)), div(i, stride))>>
  end

  defp block(sha2pass, salt, rounds, count) do
    first = bcrypt_hash(sha2pass, :crypto.hash(:sha512, salt <> <<count::32>>))

    {_last, out} =
      Enum.reduce(2..rounds//1, {first, first}, fn _, {prev, out} ->
        next = bcrypt_hash(sha2pass, :crypto.hash(:sha512, prev))
        {next, :crypto.exor(out, next)}
      end)

    out
  end

  defp bcrypt_hash(sha2pass, sha2salt) do
    state = new_state()
    expand(state, sha2salt, sha2pass)

    for _ <- 1..64 do
      expand0(state, sha2salt)
      expand0(state, sha2pass)
    end

    @magic
    |> cyclic_words(8)
    |> Tuple.to_list()
    |> encrypt_words(state, 64)
    |> Enum.map_join(&<<&1::little-32>>)
  end

  defp encrypt_words(words, _state, 0), do: words

  defp encrypt_words(words, state, times) do
    words
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn [l, r] -> Tuple.to_list(encipher(state, l, r)) end)
    |> encrypt_words(state, times - 1)
  end

  defp new_state do
    state = :atomics.new(@state_size, signed: false)
    @initial_state |> Enum.with_index(1) |> Enum.each(fn {w, i} -> :atomics.put(state, i, w) end)
    state
  end

  defp expand0(state, key) do
    xor_p(state, key)
    fill(state, 0, 0, 0, nil)
  end

  defp expand(state, data, key) do
    xor_p(state, key)
    fill(state, 0, 0, 0, cyclic_words(data, @state_size))
  end

  defp xor_p(state, key) do
    words = cyclic_words(key, 18)

    for i <- 0..17,
        do: :atomics.put(state, i + 1, bxor(:atomics.get(state, i + 1), elem(words, i)))
  end

  defp fill(_state, k, _l, _r, _data) when k == div(@state_size, 2), do: :ok

  defp fill(state, k, l, r, data) do
    {l, r} =
      if data,
        do: encipher(state, bxor(l, elem(data, 2 * k)), bxor(r, elem(data, 2 * k + 1))),
        else: encipher(state, l, r)

    :atomics.put(state, 2 * k + 1, l)
    :atomics.put(state, 2 * k + 2, r)
    fill(state, k + 1, l, r, data)
  end

  defp encipher(state, l, r) do
    {l, r} = rounds(state, bxor(l, p(state, 0)), r, 1)
    {bxor(r, p(state, 17)), l}
  end

  defp rounds(_state, l, r, n) when n > 16, do: {l, r}

  defp rounds(state, l, r, n) do
    r = bxor(r, bxor(f(state, l), p(state, n)))
    l = bxor(l, bxor(f(state, r), p(state, n + 1)))
    rounds(state, l, r, n + 2)
  end

  defp f(state, x) do
    a = :atomics.get(state, @s0 + (x >>> 24))
    b = :atomics.get(state, @s1 + (x >>> 16 &&& 0xFF))
    c = :atomics.get(state, @s2 + (x >>> 8 &&& 0xFF))
    d = :atomics.get(state, @s3 + (x &&& 0xFF))
    bxor(a + b &&& 0xFFFFFFFF, c) + d &&& 0xFFFFFFFF
  end

  defp p(state, n), do: :atomics.get(state, n + 1)

  defp cyclic_words(data, count) do
    size = byte_size(data)

    {words, _j} =
      Enum.map_reduce(1..count, 0, fn _, j ->
        word =
          Enum.reduce(0..3, 0, fn k, acc -> acc <<< 8 ||| :binary.at(data, rem(j + k, size)) end)

        {word, rem(j + 4, size)}
      end)

    List.to_tuple(words)
  end
end
