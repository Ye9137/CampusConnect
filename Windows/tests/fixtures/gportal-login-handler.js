// Login handler from the supplied page. Dependencies and endpoints are stubbed by the offline test.
function login(){
    var btn = $("#first_button");
    var name = $('#first_name').val();
    if(!name){
        showmessage("账号不能为空!", 4,null);
        return false;
    }
    /*if (!reg.test(name)) {
        showmessage("账号格式无效!", 4,null);
        return false;
    }*/
    var password = $('#first_password').val();
    if(!password){
        showmessage("密码不能为空!", 4,null);
        return false;
    }
    if($('#serverAgreement').length > 0){
        var checkAgreement = $('#serverAgreement').prop("checked");
        if(!checkAgreement){
            showmessage("请同意并勾选用户服务协议。", 4,null);
            return false;
        }
    }

    //BEGIN:fengjing add 2020-11-26
    if($('#login-protocol').length > 0){
        var agreement = $('#login-protocol').data('selected');
        if (agreement != 2) {
            showmessage("请同意并勾选用户服务协议。", 4,null);
            return false;
        }
    }
    //END:fengjing add 2020-11-26

    //BEGIN:fengjing add 2022-06-20
    var redirectUrl = $('#redirectUrl').val();
    //END:fengjing add 2022-06-20

    btn.attr('disabled', 'disabled');

    //
    showWait();

    var portalTemplateId = $("input[name='portalTemplateId']").val();
    // 加密
    var msg = cryptoEncode($("#frmLogin").serialize());
    $.ajax({
        url : "/gportal/web/authLogin?round=" + Math.round(Math.random() * 1000),
        data : msg,
        type : "post",
        async : false,
        dataType : "json",
        success : function(data) {
            closeWait();
            if (data.status === 1) {
                if(portalTemplateId == 23) {
                    showmessage(data.info, 2);
                    offlinepage();
                } else {
                showmessage(data.info, 2, data.data.redirectUrl);
                }
                $("#first_button").removeAttr('disabled');
            } else {
                $("#first_button").removeAttr('disabled');
                //doFailedLogin(data, "frmLogin");
                if (data.data.reasoncode == "40") {
                    art.dialog({
                        content: '您需要先完善自己的个人信息!',
                        okValue: '确定',
                        ok: function () {
                            //window.location.href = c.data.complete_data_url;
                            window.open(data.data.complete_data_url);
                        }
                    });
                }else if(data.data.reasoncode == "32"){
                    var name = data.data.name;
                    showmessage(data.info,4,null);
                    resetpage();
                    $("#reset_name").attr("value",name);
            } else if(data.data.reasoncode == "41"){
                art.dialog({
                            content: data.info,
                            okValue: '确定',
                            ok: function () {
                            var name = data.data.name;
                            bindpage();
                            var identitytype = data.data.identitytype;
                            var hotspotgroupid = data.data.hotspotgroupid;
                            var hotspotid = data.data.hotspotid;
                            var password = data.data.password;
                            $("#bind_identity_type").attr("value",identitytype);
                            $("#bind_identity_id").attr("value",name);
                            $("#bind_hotspot_group_id").attr("value",hotspotgroupid);
                            $("#bind_hotspot_id").attr("value",hotspotid);
                            $("#bind_password").attr("value",password);
                            }
                        });
            } else if (data.data.reasoncode == "43") {
                        art.dialog({
                            content: data.info,
                            okValue: '确定',
                            cancelValue: '取消',
                            ok: function () {
                    this.close();
                                rebindMac("frmLogin","",data.data.bindmac, 1);
                                return false;
                            },
                            cancel: function () {
                    this.close();
                                return false;
                            }
                        });
                }else {
                    showmessage(data.info, 6, null);
                }

            }
            return false;
        },error:function(jqXHR,textStatus,errorThrown){
            closeWait();
            showmessage("网络出错,请联系客服", 4, redirectUrl);
       },beforeSend:function(){
           showWait();
       }
    });
}

//获取验证码
