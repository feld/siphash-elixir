defmodule SipHash.State do
  use Bitwise
  @moduledoc """
  Module for representing state and state transformations of a digest
  whilst moving through the hasing pipeline. Note that we use tuples
  rather than structs due to a ~5 µs/op speedup. This module makes use
  of NIFs to improve performance.
  """

  # alias SipHash.Util for fast use
  alias SipHash.Util, as: Util

  # define types
  @type s :: { number, number, number, number }

  # magic 64 bit words
  @initial_v0 0x736f6d6570736575
  @initial_v1 0x646f72616e646f6d
  @initial_v2 0x6c7967656e657261
  @initial_v3 0x7465646279746573

  # define native implementation
  @native_impl [".", "_native", "state"] |> Path.join |> Path.expand

  # setup init load
  @on_load :init

  @doc """
  Loads any NIFs needed for this module. Because we have a valid fallback
  implementation, we don't have to exit on failure.
  """
  def init do
    case System.get_env("STATE_IMPL") do
      "embedded" -> :ok;
      _other -> :erlang.load_nif(@native_impl, 0)
    end
  end

  @doc """
  Applies a block (an 8-byte chunk) to the digest, and returns the state after
  transformation. A binary chunk is passed in, and then it is converted to a
  number (as little endian) before being passed to the internal function
  `SipHash.State.apply_internal_block/3`.
  """
  @spec apply_block(s, binary, number) :: s
  def apply_block({ _v0, _v1, _v2, _v3 } = state, m, c)
  when is_binary(m) and is_number(c) do
    apply_internal_block(state, Util.bytes_to_long(m), c)
  end

  # Applies a block to the digest, and returns the state after transformation.
  # First we XOR v3 before compressing the state twice. Once it's complete, we
  # then XOR v0, and return the final state.
  defp apply_internal_block({ v0, v1, v2, v3 }, m, c) do
    state = { v0, v1, v2, v3 ^^^ m }

    { v0, v1, v2, v3 } =
      state
      |> compress(c)

    { v0 ^^^ m, v1, v2, v3 }
  end

  @doc """
  Applies a last-block transformation to the digest. This block may be less than
  8-bytes, and if so we pad it left with zeroed bytes (up to 7 bytes). We then
  add the length of the input as a byte and update using the block as normal.
  """
  @spec apply_last_block({ number, s, number } | s, number, number) :: s
  def apply_last_block({ m, state, c_len }, len, c_pass) do
    last_block = case c_len do
      7 -> m
      l -> m <> :binary.copy(<<0>>, 7 - l)
    end
    apply_block(state, (last_block <> <<len>>), c_pass)
  end
  def apply_last_block({ _v0, _v1, _v2, _v3 } = state, len, c_pass) do
    apply_last_block({ <<>>, state, 0 }, len, c_pass)
  end

  @doc """
  Provides a recursive wrapper around `SipHash.Util.compress/1`. Used to easily
  modify the c-d values of the SipHash algorithm.
  """
  @spec compress(s, number) :: s
  def compress({ _v0, _v1, _v2, _v3 } = state, n) when n > 0 do
    state |> compress |> compress(n - 1)
  end
  def compress({ _v0, _v1, _v2, _v3 } = state, 0), do: state

  @doc """
  Performs the equivalent of SipRound on the provided state, making sure to mask
  numbers as it goes (because Elixir precision gets too large). Once all steps
  are completed, the new state is returned.

  Incidentally, this function is named `SipHash.State.compress/1` rather than
  `SipHash.State.round/1` to avoid clashing with `Kernel.round/1` internally.

  As of v2.0.0, this function is overridden with a native implementation when
  available in order to speed up the translations. This results in a ~10 µs/op
  speed decrease, and so this should be treated as a fallback state only.
  """
  @spec compress(s) :: s
  def compress({ v0, v1, v2, v3 }) do
    v0 = Util.apply_mask64(v0 + v1)
    v2 = Util.apply_mask64(v2 + v3)
    v1 = rotate_left(v1, 13);
    v3 = rotate_left(v3, 16);

    v1 = v1 ^^^ v0
    v3 = v3 ^^^ v2
    v0 = rotate_left(v0, 32);

    v2 = Util.apply_mask64(v2 + v1)
    v0 = Util.apply_mask64(v0 + v3)
    v1 = rotate_left(v1, 17);
    v3 = rotate_left(v3, 21);

    v1 = v1 ^^^ v2
    v3 = v3 ^^^ v0
    v2 = rotate_left(v2, 32);

    { v0, v1, v2, v3 }
  end

  @doc """
  Finalizes a digest by XOR'ing v2 and performing SipRound `d` times. After the
  rotation, all properties of the state are XOR'd from left to right.
  """
  @spec finalize(s, number) :: s
  def finalize({ v0, v1, v2, v3 }, d) when is_number(d) do
    state = { v0, v1, v2 ^^^ 0xff, v3 }

    { v0, v1, v2, v3 } =
      state
      |> compress(d)

    (v0 ^^^ v1 ^^^ v2 ^^^ v3)
  end

  @doc """
  Initializes a state based on an input key, using the technique defined in
  the SipHash specifications. First we take the input key, split it in two,
  and convert to the little endian version of the bytes. We then create a struct
  using the magic numbers and XOR them against the two key words created.
  """
  @spec initialize(binary) :: s
  def initialize(key) when is_binary(key) do
    { a, b } = :erlang.split_binary(key, 8)

    k0 = Util.bytes_to_long(a)
    k1 = Util.bytes_to_long(b)

    {
      @initial_v0 ^^^ k0,
      @initial_v1 ^^^ k1,
      @initial_v2 ^^^ k0,
      @initial_v3 ^^^ k1
    }
  end

  @doc """
  Used to quickly determine if NIFs have been loaded for this module. Returns
  `true` if it has, `false` if it hasn't.
  """
  @spec nif_loaded :: true | false
  def nif_loaded, do: false

  @doc """
  Rotates an input number `val` left by `shift` number of bits. Bits which are
  pushed off to the left are rotated back onto the right, making this a left
  rotation (a circular shift).

  ## Examples

      iex> SipHash.State.rotate_left(8, 3)
      64

      iex> SipHash.State.rotate_left(3, 8)
      768

  """
  @spec rotate_left(number, number) :: number
  def rotate_left(val, shift) when is_number(val) and is_number(shift) do
    Util.apply_mask64(val <<< shift) ||| (val >>> (64 - shift))
  end

end
