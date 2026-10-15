defmodule Sake.Auth.JWTTest do
  use ExUnit.Case, async: true

  alias Sake.Auth.JWT

  # RFC 7515 Appendix A.2 (RS256) and A.3 (ES256): the published keys and
  # signatures. Their payload expired in 2011, so they are checked "then".
  @a2 "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypGlUPQGe77Rw"
  @a2_key %{
    "kty" => "RSA",
    "n" =>
      "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ",
    "e" => "AQAB"
  }
  @a3 "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.DtEhU3ljbEg8L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"
  @a3_key %{
    "kty" => "EC",
    "crv" => "P-256",
    "x" => "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU",
    "y" => "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
  }
  @then 1_300_819_000

  # PS256 and ES384, signed by another implementation (Python's
  # `cryptography`): PSS with a 32-byte salt, and a raw 96-byte R || S.
  @ps256 "eyJhbGciOiJQUzI1NiIsImtpZCI6InBzIn0.eyJpc3MiOiJweSIsImV4cCI6NDEwMjQ0NDgwMH0.W4J0oVaX_T0GWt9Ym_N0TP-RqIn48WM6UMynHplvkZYSF4970Ardv1jfbj7VRQQ-952gmz5AGmagy4pR8psBO36Q4I3iKuW5z9hxXxIR0WYUFFOa3_BP5_yjLtKN_pJx7-xP9l50TN7v9jVI8CIGjHfB_Lsbp1pobiiC8qd-TE2dM7OqlIn5tjalek_3UVt1lM0qCH04MDo-THbXyEpoY24jEEJmJHYBxxcARUODHq5LV5GVBxJLLZQXokTJcr83bgfBpxzk9CLQ0maxrDjf9bq_HvR2InWq6OLXToEVYsGVpf_odAm3A_XYrpegUw0AJQYs12K_3rBIcR5BuqOXdg"
  @ps256_key %{
    "kty" => "RSA",
    "kid" => "ps",
    "n" =>
      "zvrnIiFyamjZ6oCUTXlxtPel9eNyZdYh-VYgKDm9_bWHFU0vALdc7V_mS1FrLGvo2S_NRF-0sYILTlvCWfuIhp_3ept5euvBnmXN0nky5FvI0odZSOceOmNTUB74GLoLfbp464GyY6O6JcMJEKZ7ATguX5jdsc4w7x8uu7HlRPf61iDgpTeS89_Cq8XVltQo3pROB7VEWkT-p51N9NsHckA7iJ_igeKUrVWoDn_edtTDy8Y-upklirWxUQMkBFOc5JcedH-C2gY-E9qqP7crw9Kh26Wgmp7Gamd45bBDNs-nt6g4w1HByN5-LJiWLzWy_8igcNUBIUuXmJGODYADzw",
    "e" => "AQAB"
  }
  @es384 "eyJhbGciOiJFUzM4NCJ9.eyJpc3MiOiJweSIsImV4cCI6NDEwMjQ0NDgwMH0.yBh8Sbm1A4dcOvJ44MfWpWiUWQLRKNhjHavNCeM5QCDcuixDKc8WwgBJHXtrL0BH4jLW_01z649r38IVALvY4KL0LB0O_D8rbSCnP-6kRIARbGAuBS8X2rMjMYq-RYDf"
  @es384_key %{
    "kty" => "EC",
    "crv" => "P-384",
    "x" => "e-De0QcS8FkfIe7daZGLLSTvLuOkIsFBhdW21AUgNwEHRsn1JulEnixMMn49WWon",
    "y" => "vZEka12QnL-Cu03SRY5eK_Kx93yW9Flcq47S7hXhEgwCR03PzZ1zVRU2i51ddj4j"
  }

  defp pem(:ec), do: pem({:namedCurve, :secp256r1})
  defp pem(:p384), do: pem({:namedCurve, :secp384r1})
  defp pem(:rsa), do: pem({:rsa, 2048, 65_537})

  defp pem(spec) do
    key = :public_key.generate_key(spec)
    :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
  end

  defp key(kind) do
    {:ok, key} = kind |> pem() |> JWT.private_key()
    key
  end

  defp b64(data), do: Base.url_encode64(data, padding: false)
  defp segment(map), do: map |> JSON.encode!() |> b64()

  defp claims(extra \\ %{}),
    do:
      Map.merge(
        %{"iss" => "https://idp.example", "exp" => System.system_time(:second) + 60},
        extra
      )

  describe "published vectors" do
    test "RFC 7515 A.2 (RS256) and A.3 (ES256) verify" do
      assert {:ok, %{"iss" => "joe", "http://example.com/is_root" => true}} =
               JWT.verify(@a2, [@a2_key], now: @then)

      assert {:ok, %{"iss" => "joe"}} = JWT.verify(@a3, %{"keys" => [@a3_key]}, now: @then)
    end

    test "PS256 and ES384 from another implementation verify" do
      assert {:ok, %{"iss" => "py"}} = JWT.verify(@ps256, [@ps256_key])
      assert {:ok, %{"iss" => "py"}} = JWT.verify(@es384, [@es384_key])
    end

    test "a changed payload, signature or header no longer verifies" do
      [h, p, s] = String.split(@a2, ".")
      other = segment(%{"iss" => "eve", "exp" => 1_300_819_380})

      assert {:error, :bad_signature} = JWT.verify("#{h}.#{other}.#{s}", [@a2_key], now: @then)

      flipped =
        s
        |> Base.url_decode64!(padding: false)
        |> :binary.bin_to_list()
        |> List.update_at(10, &Bitwise.bxor(&1, 1))

      assert {:error, :bad_signature} =
               JWT.verify("#{h}.#{p}.#{b64(:binary.list_to_bin(flipped))}", [@a2_key], now: @then)

      # The same RSA signature presented as PS256 is not a PSS signature.
      ps = segment(%{"alg" => "PS256"})
      assert {:error, :bad_signature} = JWT.verify("#{ps}.#{p}.#{s}", [@a2_key], now: @then)

      # Another key of the right type does not verify it either.
      assert {:error, :bad_signature} = JWT.verify(@a3, [JWT.public_jwk(key(:ec))], now: @then)
    end

    test "an ECDSA signature must be the raw R || S of the curve's size" do
      [h, p, s] = String.split(@a3, ".")
      raw = Base.url_decode64!(s, padding: false)
      <<r::binary-size(32), sig_s::binary-size(32)>> = raw

      der =
        :public_key.der_encode(
          :"ECDSA-Sig-Value",
          {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(sig_s)}
        )

      assert {:error, :bad_signature} = JWT.verify("#{h}.#{p}.#{b64(der)}", [@a3_key], now: @then)

      assert {:error, :bad_signature} =
               JWT.verify("#{h}.#{p}.#{b64(raw <> <<0>>)}", [@a3_key], now: @then)
    end
  end

  describe "sign/4" do
    test "round trips with every algorithm" do
      for {kind, alg} <- [rsa: "RS256", rsa: "PS256", ec: "ES256", p384: "ES384"] do
        key = key(kind)
        token = JWT.sign(claims(), key, alg, %{"typ" => "test+jwt", "kid" => "k1"})
        jwk = Map.put(JWT.public_jwk(key), "kid", "k1")

        assert {:ok, %{"iss" => "https://idp.example"}} =
                 JWT.verify(token, [jwk], typ: "test+jwt", algs: [alg])

        assert {:ok, %{"alg" => ^alg, "kid" => "k1", "typ" => "test+jwt"}, _} = JWT.peek(token)
      end
    end

    test "the default algorithm follows the key, and a key signs only its own" do
      assert JWT.default_alg(key(:rsa)) == "RS256"
      assert JWT.default_alg(key(:ec)) == "ES256"
      assert JWT.default_alg(key(:p384)) == "ES384"
      assert_raise ArgumentError, fn -> JWT.sign(claims(), key(:ec), "RS256") end
      assert_raise ArgumentError, fn -> JWT.sign(claims(), key(:rsa), "ES256") end
      assert_raise FunctionClauseError, fn -> JWT.sign(claims(), key(:rsa), "HS256") end
    end

    test "private_key/1 reads PKCS #8 and traditional keys, and refuses anything else" do
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      traditional = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])
      assert {:ok, key} = JWT.private_key(traditional)
      refute Map.has_key?(JWT.public_jwk(key), "d")

      ec = :public_key.generate_key({:namedCurve, :secp256r1})

      assert {:ok, _} =
               JWT.private_key(
                 :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, ec)])
               )

      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = rsa

      public =
        :public_key.pem_encode([
          :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})
        ])

      assert {:error, :invalid_key} = JWT.private_key(public)

      weak = :public_key.generate_key({:rsa, 1024, 65_537})

      assert {:error, :invalid_key} =
               JWT.private_key(
                 :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, weak)])
               )

      assert {:error, :invalid_key} = JWT.private_key("not a key")
      assert {:error, :invalid_key} = JWT.private_key(nil)
    end
  end

  describe "refused tokens" do
    setup do
      key = key(:ec)
      %{key: key, jwks: %{"keys" => [Map.put(JWT.public_jwk(key), "kid", "a")]}}
    end

    test "alg none, HMAC, unknown or disallowed algorithms", %{key: key, jwks: jwks} do
      payload = segment(claims())

      assert {:error, :unsupported_alg} =
               JWT.verify("#{segment(%{"alg" => "none"})}.#{payload}.", jwks)

      # An HMAC keyed with the public key's own bytes: the confusion attack.
      secret = JSON.encode!(hd(jwks["keys"]))
      input = "#{segment(%{"alg" => "HS256"})}.#{payload}"
      mac = b64(:crypto.mac(:hmac, :sha256, secret, input))
      assert {:error, :unsupported_alg} = JWT.verify("#{input}.#{mac}", jwks)

      assert {:error, :unsupported_alg} =
               JWT.verify("#{segment(%{"alg" => "EdDSA"})}.#{payload}.c2ln", jwks)

      assert {:error, :malformed} =
               JWT.verify("#{segment(%{"typ" => "JWT"})}.#{payload}.c2ln", jwks)

      token = JWT.sign(claims(), key, "ES256")
      assert {:error, :unsupported_alg} = JWT.verify(token, jwks, algs: ["RS256"])
    end

    test "no key of the algorithm's type, kid, use or alg", %{key: key, jwks: jwks} do
      token = JWT.sign(claims(), key, "ES256", %{"kid" => "a"})
      assert {:ok, _} = JWT.verify(token, jwks)

      [jwk] = jwks["keys"]
      assert {:error, :no_key} = JWT.verify(token, [%{jwk | "kid" => "b"}])
      assert {:error, :no_key} = JWT.verify(token, [Map.put(jwk, "use", "enc")])
      assert {:error, :no_key} = JWT.verify(token, [Map.put(jwk, "alg", "ES384")])
      assert {:error, :no_key} = JWT.verify(token, [@a2_key, @es384_key])
      assert {:error, :no_key} = JWT.verify(token, [%{"kty" => "oct", "k" => "c2VjcmV0"}])
      assert {:error, :no_key} = JWT.verify(token, [])
      assert {:error, :no_key} = JWT.verify(token, "not a key set")

      # A JWK with private material is not a published verification key.
      assert {:error, :no_key} = JWT.verify(token, [Map.put(jwk, "d", "x")])

      # An RSA key under 2048 bits is never used.
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} =
        :public_key.generate_key({:rsa, 1024, 65_537})

      weak = %{
        "kty" => "RSA",
        "n" => b64(:binary.encode_unsigned(n)),
        "e" => b64(:binary.encode_unsigned(e))
      }

      [h, p, _] = String.split(@a2, ".")
      assert {:error, :no_key} = JWT.verify("#{h}.#{p}.c2ln", [weak], now: @then)
    end

    test "malformed tokens", %{jwks: jwks} do
      header = segment(%{"alg" => "ES256"})

      for token <- [
            nil,
            "",
            "a.b",
            "a.b.c.d",
            "#{header}.!!.c2ln",
            "#{header}.#{b64("not json")}.c2ln",
            "#{header}.#{b64("[1]")}.c2ln",
            "#{b64("[]")}.#{segment(claims())}.c2ln",
            "#{header}.#{segment(claims())}.!!"
          ] do
        assert {:error, :malformed} = JWT.verify(token, jwks), inspect(token)
      end
    end

    test "a crit header is not understood", %{key: key, jwks: jwks} do
      token = JWT.sign(claims(), key, "ES256", %{"crit" => ["exp"]})
      assert {:error, :unsupported_alg} = JWT.verify(token, jwks)
    end

    test "typ", %{key: key, jwks: jwks} do
      typed = JWT.sign(claims(), key, "ES256", %{"typ" => "oauth-id-jag+jwt"})
      assert {:ok, _} = JWT.verify(typed, jwks, typ: "oauth-id-jag+jwt")
      prefixed = JWT.sign(claims(), key, "ES256", %{"typ" => "Application/OAuth-ID-JAG+JWT"})
      assert {:ok, _} = JWT.verify(prefixed, jwks, typ: "oauth-id-jag+jwt")
      assert {:error, :invalid_typ} = JWT.verify(typed, jwks, typ: "JWT")

      assert {:error, :invalid_typ} =
               JWT.verify(JWT.sign(claims(), key, "ES256"), jwks, typ: "JWT")
    end

    test "times, with the leeway", %{key: key, jwks: jwks} do
      now = System.system_time(:second)
      sign = &JWT.sign(&1, key, "ES256")

      assert {:error, :expired} = JWT.verify(sign.(claims(%{"exp" => now - 31})), jwks)
      assert {:ok, _} = JWT.verify(sign.(claims(%{"exp" => now - 20})), jwks)
      assert {:error, :expired} = JWT.verify(sign.(claims(%{"exp" => now - 20})), jwks, leeway: 0)
      assert {:error, :not_yet_valid} = JWT.verify(sign.(claims(%{"nbf" => now + 60})), jwks)
      assert {:ok, _} = JWT.verify(sign.(claims(%{"nbf" => now + 10})), jwks)
      assert {:error, :issued_in_future} = JWT.verify(sign.(claims(%{"iat" => now + 60})), jwks)
      assert {:error, :malformed} = JWT.verify(sign.(claims(%{"exp" => "tomorrow"})), jwks)

      assert {:error, {:missing_claim, "exp"}} =
               JWT.verify(sign.(Map.delete(claims(), "exp")), jwks)

      assert {:ok, _} = JWT.verify(sign.(Map.delete(claims(), "exp")), jwks, required: [])

      assert {:error, {:missing_claim, "jti"}} =
               JWT.verify(sign.(claims()), jwks, required: ["exp", "jti"])
    end

    test "issuer and audience", %{key: key, jwks: jwks} do
      token = JWT.sign(claims(%{"aud" => ["https://as.example", "other"]}), key, "ES256")

      assert {:ok, _} =
               JWT.verify(token, jwks, iss: "https://idp.example", aud: "https://as.example")

      assert {:ok, _} = JWT.verify(token, jwks, aud: ["x", "other"])
      assert {:error, :invalid_issuer} = JWT.verify(token, jwks, iss: "https://idp.example/")
      assert {:error, :invalid_audience} = JWT.verify(token, jwks, aud: "https://as.example/")

      single = JWT.sign(claims(%{"aud" => "https://as.example"}), key, "ES256")
      assert {:ok, _} = JWT.verify(single, jwks, aud: ["https://as.example"])

      assert {:error, :invalid_audience} =
               JWT.verify(JWT.sign(claims(), key, "ES256"), jwks, aud: "a")

      assert {:error, :invalid_audience} =
               JWT.verify(JWT.sign(claims(%{"aud" => 1}), key, "ES256"), jwks, aud: "a")

      assert {:error, :invalid_issuer} =
               JWT.verify(
                 JWT.sign(%{"exp" => System.system_time(:second) + 9}, key, "ES256"),
                 jwks,
                 iss: "a"
               )
    end
  end
end
