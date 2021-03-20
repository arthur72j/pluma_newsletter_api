defmodule PlumaApiWeb.SubscriberControllerTest do
  use PlumaApiWeb.ConnCase
  use PlumaApi.TestUtils
  alias PlumaApi.Subscriber
  alias PlumaApi.Repo

  @moduletag :subscriber_controller_tests
  @list_id Keyword.get(Application.get_env(:pluma_api, :mailchimp), :main_list_id)

  # Tests both ?rid and ?email params
  test "get_subscriber/2", %{conn: conn} do
    {:ok, subscriber} =
        Subscriber.insert_changeset(%Subscriber{}, PlumaApi.Factory.subscriber())
        |> Repo.insert

    conn_email = get(conn, Routes.subscriber_path(conn, :get_subscriber), %{email: subscriber.email})
    conn_rid = get(conn, Routes.subscriber_path(conn, :get_subscriber), %{rid: subscriber.rid})

    assert json_response(conn_email, 200)
    assert json_response(conn_rid, 200)

    assert conn_email.resp_body =~ subscriber.email
    assert conn_rid.resp_body =~ subscriber.email

    conn_email_failure = get(conn, Routes.subscriber_path(conn, :get_subscriber), %{email: "nonexistent@email.com"})
    conn_rid_failure = get(conn, Routes.subscriber_path(conn, :get_subscriber), %{rid: "111111111"})

    assert json_response(conn_email_failure, 404)
    assert json_response(conn_email_failure, 404)

    assert Jason.decode!(conn_email_failure.resp_body) == %{ "errors" => %{ "detail" => "Could not find subscriber" } }
    assert Jason.decode!(conn_rid_failure.resp_body) == %{ "errors" => %{ "detail" => "Could not find subscriber" } }
  end

  @tag test_sub: PlumaApi.Factory.subscriber()
  test "new_subscriber/2", %{conn: conn, test_sub: test_sub} do
    conn_new = post(conn, Routes.subscriber_path(conn, :new_subscriber), make_new_subscriber_call(test_sub))

    assert json_response(conn_new, 200)
    assert %{"status" => _status, "detail" => _detail, "stage" => _stage} = Jason.decode!(conn_new.resp_body)
    assert PlumaApi.MailchimpRepo.check_exists(test_sub.email, @list_id)

    conn_existing = post(conn, Routes.subscriber_path(conn, :new_subscriber), make_new_subscriber_call(test_sub))

    assert json_response(conn_existing, 400)
    assert %{"status" => _status, "detail" => _detail, "stage" => _stage} = Jason.decode!(conn_new.resp_body)

    conn_invalid = post(conn, Routes.subscriber_path(conn, :new_subscriber), %{"fname" => "", "lname" => "", "email" => "not_an_email", "rid" => "111111", "prid" => ""})

    assert json_response(conn_invalid, 400)
  end

  defp make_new_subscriber_call(factory_sub) when is_map(factory_sub) do
    %{
      "fname" => Faker.Person.En.first_name(),
      "lname" => Faker.Person.En.last_name(),
      "email" => factory_sub.email,
      "rid" => factory_sub.rid,
      "prid" => factory_sub.parent_rid,
      "ip_signup" => Faker.Internet.ip_v4_address()
    }
  end

end
